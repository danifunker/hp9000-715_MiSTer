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
    parameter logic [5:0] CPU_REVISION = 6'd2       // DR0 bits 0:5 (cpu-requests #2)
) (
    input  logic        clk,
    input  logic        rst_n,

    // from / to pa_fetch
    input  logic        f2_valid,
    input  logic [31:0] f2_insn,
    input  logic [31:0] f2_iaoq_f, f2_iaoq_b,
    input  logic [15:0] f2_iasq_f, f2_iasq_b,
    input  logic        f2_err,
    input  logic [3:0]  f2_perr,
    input  logic        f2_itlb, f2_imp,
    input  logic [2:0]  f2_type,
    output logic        psw_c_o,
    output logic [4:0]  ihash_o,
    output logic [31:0] dr8_o,
    output logic        adv_f2,
    output logic        drained,
    output logic        uib_inval,
    output logic        redir,
    output logic        redir_kill_all,
    output logic        ilab_inval,                   // the I-LAB is refreshed (ERS s.6.4)
    output logic [31:0] redir_target, redir_back,
    output logic [15:0] redir_space, redir_back_space,
    output logic        redir_new_space,
    output logic [31:0] redir_slot_e, redir_slot_d,   // E's / D's branch delay-slot address
    output logic        redir_from_e,
    output logic        redir_slot_in_d,   // E's redirect with its delay slot held in D
    output logic        redir_d,           // D's prediction redirects (whether or not E/W override it)
    output logic [31:0] redir_d_target,    // its target, free of E's adder (the fetch's early lookup)

    // TLB (pa_tlb)
    output logic [15:0] tlb_lk_space,   // the next lookup tag (E's address or the I-LAB's request)
    output logic [19:0] tlb_lk_vpn,
    output logic        tlb_lk_load,    // the TLB registers its compare this edge
    input  logic [35:0] tlb_lk_tag_r,   // the tag the registered match belongs to
    input  logic        tlb_op_accept,
    output logic        tlb_lk_use,
    input  logic        tlb_lk_hit,
    input  logic [19:0] tlb_lk_rpn,
    input  logic [6:0]  tlb_lk_ar,
    input  logic [14:0] tlb_lk_aid,
    input  logic        tlb_lk_pid_rd, tlb_lk_pid_wr,
    output logic [15:0] pid_o [4],
    input  logic        tlb_lk_t, tlb_lk_d, tlb_lk_b, tlb_lk_u,
    // FP unit (pa_fpunit): operations issue at W commit, loads write at W commit,
    // stores read in W; the unit's busy / FPSR.T / FPSR feed D's stall and E's traps
    output logic        fp_issue,
    output logic [31:0] fp_insn,
    output logic        fp_ld_we,
    output logic [63:0] fp_ld_data,
    output logic        fp_st_dbl,          // the store in W is FSTD (w_c.size): the FPU's store-data select without an opcode decode
    output logic        fp_st_commit,
    input  logic [63:0] fp_st_data,
    input  logic        fp_busy,
    input  logic        fp_t,
    input  logic [31:0] fpsr,
    output logic        tlb_op_req,
    output tlb_op_e     tlb_op,
    output logic [15:0] tlb_op_space,
    output logic [31:0] tlb_op_off, tlb_op_gr,
    input  logic        tlb_op_done,
    input  logic        tlb_op_cam,         // the TLB's CAM is comparing an operation's tag this cycle
    // the fetch unit's I-LAB refill (served when M does not need the TLB)
    input  logic        it_req,
    input  logic [15:0] it_space,
    input  logic [19:0] it_vpn,
    output logic        it_ack, it_hit,
    output logic [19:0] it_rpn,
    output logic [3:0]  it_xok,
    output logic [2:0]  it_type,
    // D-cache (pa_dcache)
    input  logic        dc_ready,
    output logic        dc_lk_en,
    output logic [4:0]  dc_lk_hash, dc_st_hash, dc_op_hash, dc_m_hash,
    output logic [19:0] dc_m_rpn, dc_st_rpn, dc_op_rpn,
    output logic        dc_st_fwd,
    input  logic [127:0] dc_op_rd2,
    input  logic [63:0] dc_op_dw,       // the missed doubleword, filled (misses complete in W)
    output logic [31:0] dc_lk_addr, dc_m_addr,
    input  logic [63:0] dc_m_rdata,
    input  logic        dc_m_hit, dc_m_dirty,
    input  logic [3:0]  dc_m_perr,
    output logic        dc_st_we,
    output logic [31:0] dc_st_addr,
    output logic [63:0] dc_st_data,
    output logic        dc_op_req,
    output dc_op_e      dc_op,
    output logic [31:0] dc_op_addr, dc_op_wdata,
    input  logic        dc_op_done, dc_op_err, dc_op_hit,
    input  logic [3:0]  dc_op_perr,
    input  logic [31:0] dc_op_rdata,
    // I-cache operations (pa_icache)
    input  logic        ic_ready,
    output logic        ic_op_req,
    output ic_op_e      ic_op,
    output logic [31:0] ic_op_addr, ic_op_wdata,
    output logic [4:0]  ic_op_hash,
    output logic [19:0] ic_op_rpn,
    output logic [31:0] ic_dr27, ic_dr28, ic_dr29,
    input  logic        ic_op_done, ic_op_hit,
    input  logic [3:0]  ic_op_perr,
    input  logic [31:0] ic_op_rdata, ic_rd_dr27, ic_rd_dr28, ic_rd_dr29,
    output logic        ic_l1_en,
    // BIU data port (uncached)
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
    // cpu-requests #10 (board recorder): the retired instruction's EA and store
    // datum; W-hold events (1 D-cache miss, 2 walk, 3 replay) with their IAOQ/EA
    output logic [31:0] dbg_ea, dbg_stdata,
    output logic [1:0]  dbg_wev,
    output logic [31:0] dbg_wev_iaoq, dbg_wev_ea,
    output logic [31:0] dbg_psw,
    output logic        dbg_halted,
    output logic        dbg_fp_stall,   // D held an FP instruction this cycle only because of the FPU (S-012)
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
    logic [31:0] dr0, dr8, dr24, dr25, dr26;
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
    logic [3:0]  d_fperr, e_fperr, m_fperr, w_fperr;
    logic        d_itlb, d_imp, e_itlb, e_imp;
    logic [2:0]  d_type, e_type;
    logic [31:0] d_insn, d_iaoq_f, d_iaoq_b;
    logic [15:0] d_iasq_f, d_iasq_b;
    // ---- E
    logic        e_valid, e_nul, e_err, e_pred, e_bflag;
    logic [31:0] e_insn, e_iaoq_f, e_iaoq_b, e_gra, e_grb, e_target;
    logic [15:0] e_iasq_f, e_iasq_b;
    ctrl_t       e_c;
    logic [1:0]  e_fa_sel, e_fb_sel;      // 0 reg (D read or bypass), 1 M port0, 2 M port1
    logic        e_bp_ld;                 // an operand was bypassed in D from the load then in M
    logic        e_bp_ld_a, e_bp_ld_b;   // which operand it was (the late load patches it in E)
    logic [4:0]  e_sar_r;                 // SAR as of D (bypassed from an MTSAR in M/W)
    logic [1:0]  e_cb_sel, e_v_sel, e_sar_sel;  // 0 PSW/reg, 1 M, 2 W
    // ---- M
    logic        m_valid, m_nul, m_err, m_taken, m_nullify, m_new_space;
    logic [31:0] m_insn, m_iaoq_f, m_iaoq_b, m_result, m_base, m_ea, m_target;
    logic [15:0] m_iasq_f, m_iasq_b;
    logic [5:0]  m_trap;
    logic        m_trap_data;
    logic [7:0]  m_cb;
    logic        m_v;
    logic [3:0]  m_be;
    logic [31:0] m_stdata;
    logic [15:0] m_space;
    logic [4:0]  m_hash;
    logic [1:0]  m_pl, m_ppl;
    logic        m_xlate;               // the access translates (TLB lookup in M)
    logic        m_need;                // = m_valid && !m_nul && m_xlate, registered at E -> M so the
                                        //   TLB port select is one LUT from flops (cpu-timing.md 4.3 cut M2)
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
    logic        w_cached, w_hit, w_dirty, w_opflush;
    logic        w_stfill;              // a store (or LDCW) whose line was filled in W: write it at W_DONE, no flush
    logic [19:0] w_rpn;
    logic [4:0]  w_hash;
    logic        w_walk;                // the TLB miss may be walked
    logic [31:0] w_pdir_a;              // the walker's PDIR entry address
    logic [3:0]  w_dperr;
    logic [63:0] w_stdw;
    ctrl_t       w_c;
    logic [63:0] w_ld;                  // load data: the word in [31:0], a doubleword (FLDD) whole
    logic        w_lderr;
    logic [31:0] set_tag;                // SET_TAG latch (ERS s.8.3.5)
    logic [31:0] dr27, dr28, dr29;

    // nullify / taken-branch state for instructions entering E
    logic        pending_nul, prev_taken;
    // group 4 trap armed for the next instruction
    logic        g4_pend;
    logic [5:0]  g4_vec;

    // ================================================================ W-stage control (declared early)
    typedef enum logic [3:0] { W_RUN, W_WAIT, W_DONE, W_OP, W_REPLAY, W_WALK_RD, W_WALK_A, W_WALK_P, W_WFAIL, W_WALK_RD3 } wst_e;
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

    // Operand bypasses in D (cpu-timing.md 4.8): E forwards only from M, so D
    // takes the newest value from M (the ALU result, the base update, or the
    // cache word of a load) ahead of W's write-through (port 0 wins). The
    // selects use what M / W *would* write, not whether they commit: if W
    // traps or holds instead, D's instruction is killed or re-read. A load's
    // word from M is right for a cache hit; a miss replays everything from the
    // load, and a load that completes later in W (uncached, LDCW through
    // memory) refetches the consumer (`w_refetch`). The other late results
    // (PROBE, LPA, LDSID, LCI, DIAG reads) hold the consumer in D instead.
    wire bp0 = w_valid && !w_nul && w_c.rt_we && w_c.rt != 0;
    wire bp1 = w_valid && !w_nul && w_c.base_we && w_c.rb != 0;
    wire m_fw = m_valid && !m_nul;
    wire m_gload = m_c.fu == FU_LOAD && !m_c.fpm;
    wire mp0 = m_fw && m_c.rt_we && m_c.rt != 0;
    wire mp1 = m_fw && m_c.base_we && m_c.rb != 0;
    wire [31:0] m_fw_rt = m_gload ? m_ld : m_result;
    wire bp_ld_a = dc.ra != 0 && mp0 && m_c.rt == dc.ra && m_gload;
    wire bp_ld_b = dc.rb != 0 && mp0 && m_c.rt == dc.rb && m_gload;
    always_comb begin
        gra_d = rd0; grb_d = rd1;
        if (dc.ra != 0) begin
            if (mp0 && m_c.rt == dc.ra)      gra_d = m_fw_rt;
            else if (mp1 && m_c.rb == dc.ra) gra_d = m_base;
            else if (bp0 && wa0 == dc.ra)    gra_d = wd0;
            else if (bp1 && wa1 == dc.ra)    gra_d = wd1;
        end
        if (dc.rb != 0) begin
            if (mp0 && m_c.rt == dc.rb)      grb_d = m_fw_rt;
            else if (mp1 && m_c.rb == dc.rb) grb_d = m_base;
            else if (bp0 && wa0 == dc.rb)    grb_d = wd0;
            else if (bp1 && wa1 == dc.rb)    grb_d = wd1;
        end
    end

    // interlocks
    wire [4:0] d_f6_10  = d_insn[25:21];
    wire [4:0] d_f11_15 = d_insn[20:16];
    // results that are not in m_result when the instruction is in M
    function automatic logic late_rt(input ctrl_t c);
        late_rt = (c.fu == FU_LOAD && !c.fpm) || (c.fu == FU_SYS && c.sysop == SYS_LDSID) ||
                  (c.fu == FU_MMU && (c.sysop == MM_PROBE || c.sysop == MM_LPA || c.sysop == MM_LCI)) ||
                  (c.fu == FU_DIAG && c.rt_we);
    endfunction
    wire ld_use = (e_valid && !e_nul && late_rt(e_c) && e_c.rt != 0 &&
                   (e_c.rt == d_f6_10 || e_c.rt == d_f11_15)) ||
                  (m_valid && !m_nul && late_rt(m_c) && !m_gload && m_c.rt != 0 &&
                   (m_c.rt == d_f6_10 || m_c.rt == d_f11_15));
    function automatic logic ser_stall(input ctrl_t c);
        ser_stall = (c.fu == FU_SYS) && (c.sysop == SYS_MTSP || (c.sysop == SYS_MTCTL && c.cr != 5'd11));
    endfunction
    wire ser_pending = (e_valid && ser_stall(e_c)) || (m_valid && ser_stall(m_c)) || (w_valid && ser_stall(w_c));
    // an FP instruction waits in D while an FP operation is in E/M/W or in the unit
    // (operands are read and results written in order at W, so nothing else is
    // needed), and while an FP load or store of fr0-fr3 is in E/M/W: FSTD fr0
    // clears T and FLD fr0 rewrites the whole status at W commit, and the next
    // FP instruction's trap-14 check in E must see the result (sec. 3.5; the
    // real chip interlocks these for 4 cycles, ERS s.7.5.6)
    wire d_is_fp = dc.fu == FU_FP || dc.fpm;
    function automatic logic fp_ctl_access(input ctrl_t c, input logic [31:0] insn);
        fp_ctl_access = c.fpm && insn[4:0] < 5'd4;
    endfunction
    wire fp_pending = fp_busy || (e_valid && (e_c.fu == FU_FP || fp_ctl_access(e_c, e_insn))) ||
                      (m_valid && (m_c.fu == FU_FP || fp_ctl_access(m_c, m_insn))) ||
                      (w_valid && (w_c.fu == FU_FP || fp_ctl_access(w_c, w_insn)));
    wire d_stall = d_valid && (ld_use || ser_pending || (d_is_fp && fp_pending));
    assign dbg_fp_stall = adv && d_valid && d_is_fp && fp_pending && !ld_use && !ser_pending;
    wire adv_d = adv && !d_stall;              // D -> E this cycle
    assign adv_f2 = adv_d;                     // F2 -> D (also when D is empty)

    // forwarding selects for the instruction entering E (what will be in M then;
    // anything older was bypassed in D)
    function automatic logic [1:0] fsel(input logic [4:0] r);
        fsel = 2'd0;
        if (r != 0) begin
            if (e_valid && !e_nul && e_c.rt_we && e_c.rt == r)              fsel = 2'd1;
            else if (e_valid && !e_nul && e_c.base_we && e_c.rb == r)       fsel = 2'd2;
        end
    endfunction
    wire e_mtsar = e_c.fu == FU_SYS && e_c.sysop == SYS_MTCTL && e_c.cr == 5'd11;
    wire m_mtsar = m_c.fu == FU_SYS && m_c.sysop == SYS_MTCTL && m_c.cr == 5'd11;
    wire [1:0] d_cb_sel  = (e_valid && !e_nul && e_c.cb_we) ? 2'd1 : (m_valid && !m_nul && m_c.cb_we) ? 2'd2 : 2'd0;
    wire [1:0] d_v_sel   = (e_valid && !e_nul && e_c.ds)    ? 2'd1 : (m_valid && !m_nul && m_c.ds)    ? 2'd2 : 2'd0;
    wire w_mtsar = w_c.fu == FU_SYS && w_c.sysop == SYS_MTCTL && w_c.cr == 5'd11;
    wire [1:0] d_sar_sel = (e_valid && !e_nul && e_mtsar) ? 2'd1 : 2'd0;
    // SAR as D sees it: an MTSAR in M or W bypassed, else the register
    wire [4:0] d_sar = (m_valid && !m_nul && m_mtsar) ? m_result[4:0] :
                       (w_valid && !w_nul && w_mtsar) ? w_result[4:0] : sar;

    // static prediction
    wire e_is_branch = e_valid && e_c.fu == FU_BRANCH;
    // the PC-relative target is added a stage early, from F2's registers, and
    // registered into D (`d_target_r`): D's prediction then redirects the fetch
    // from a register, which the I-cache's address register can take in the same
    // cycle (fit 18, cpu-timing.md). BE/BLE/BV/BLR targets come from E's operands.
    wire [31:0] f2_disp   = (f2_insn[31:26] == 6'h3A) ? br_disp17(f2_insn) : br_disp12(f2_insn);
    wire [31:0] f2_target = f2_iaoq_f + 32'd8 + f2_disp;
    logic [31:0] d_target_r;
    wire [31:0] d_target = (dc.br == BR_GATE) ? {d_target_r[31:2], 2'b00} : d_target_r;   // GATE: PL 0 (C = 0)
    wire d_pred = d_valid && dc.fu == FU_BRANCH && !dc.illegal && !e_is_branch &&
                  ((dc.br == BR_COND && dc.disp[31]) || dc.br == BR_BL || dc.br == BR_GATE);
    wire d_redir = d_pred && adv_d;

    // ================================================================ E stage
    // operands
    logic [31:0] fa, fb, opa;
    always_comb begin
        case (e_fa_sel)
            2'd1: fa = m_result; 2'd2: fa = m_base;
            default: fa = e_gra;
        endcase
        case (e_fb_sel)
            2'd1: fb = m_result; 2'd2: fb = m_base;
            default: fb = e_grb;
        endcase
        opa = e_c.a_imm ? e_c.imm : fa;
    end
    wire [7:0] cb_in  = (e_cb_sel == 2'd1) ? m_cb : (e_cb_sel == 2'd2) ? w_cb : psw[15:8];
    wire       v_in   = (e_v_sel == 2'd1)  ? m_v  : (e_v_sel == 2'd2)  ? w_v  : psw[P_V];
    wire [4:0] sar_in = (e_sar_sel == 2'd1) ? m_result[4:0] : e_sar_r;
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

    // the data space and virtual address of the instruction in E: the (s,b) rule,
    // the 3-bit sr field of the I-side TLB/cache ops, or IIAQ / ISR+IOR for the
    // fast inserts
    wire [15:0] e_sp = e_c.tlb_fast ? (e_c.tlb_i ? iiasq_f : isr) :
                       e_c.tlb_i    ? sr[e_c.sr] :
                       (e_c.s2 != 0) ? sr[e_c.s2] : sr[{1'b1, fb[31:30]}];
    wire [31:0] e_va = e_c.tlb_fast ? (e_c.tlb_i ? iiaoq_f : ior) : ls_ea;
    function automatic logic [4:0] hash_of(input logic [15:0] sp);     // cpu.md 2.7
        return {sp[4], sp[3], sp[0], sp[1], sp[2]};
    endfunction
    wire e_is_data = e_c.fu == FU_LOAD || e_c.fu == FU_STORE;
    wire e_is_na   = e_c.fu == FU_MMU && (e_c.sysop == MM_FDC || e_c.sysop == MM_PDC || e_c.sysop == MM_FIC);
    wire e_rdtlb   = e_c.fu == FU_DIAG && e_c.sysop == DG_RDTLB;
    wire e_xlate   = ((e_is_data && !e_c.absolute) || e_is_na) && psw[P_D] ||
                     (e_c.fu == FU_MMU && (e_c.sysop == MM_PROBE || e_c.sysop == MM_LPA)) || e_rdtlb;
    wire [4:0] e_hash = (((e_is_data || e_is_na) && psw[P_D]) || e_rdtlb) && dr0[4] ? hash_of(e_sp) : 5'd0;

    // D-cache lookup for the instruction moving into M
    assign dc_lk_en   = adv;
    assign dc_lk_addr = ls_ea;
    assign dc_lk_hash = e_hash;
    assign dc_m_addr  = m_ea;
    assign dc_m_hash  = m_hash;
    wire [31:0] ls_wd_eff = e_c.ldcw ? 32'd0 : ls_wd;          // LDCW clears the word
    wire e_unal = (e_c.size == 2'd3) ? |e_va[2:0] : ls_unaligned; // doublewords: 8-byte aligned
    wire e_fstd_fr0 = e_c.fpm && e_c.fu == FU_STORE && e_c.size == 2'd3 && e_insn[4:0] == 5'd0;

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
            BR_GATE: br_target = {e_target[31:2], gate_pl};             // promotion from the page's AR type
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
    // GATE: C = 0 -> PL 0; C = 1 -> min(current, type{1:2}) when the page's type >= 4, else unchanged
    wire [1:0] gate_pl = !psw[P_C] ? 2'b00 : !e_type[2] ? cur_pl : (e_type[1:0] < cur_pl ? e_type[1:0] : cur_pl);
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
            FU_FP:     e_nullify = e_c.fp_ftest && ftest_valid(e_insn[4:0]) && ftest_cond(fpsr, e_insn[4:0]);
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
            FU_MMU:  e_result = fa;                                      // IxTLBx: GR[r]
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
        else if (e_itlb) e_trap = TRAP_ITLB;
        else if (e_imp) e_trap = TRAP_IMP;
        else if (e_c.fu == FU_DIAG && cur_pl != 2'd0)          // DIAG: privilege before the encoding check
            e_trap = TRAP_PRIV_OP;
        else if (e_c.illegal || (e_c.fu == FU_BRANCH && e_c.br == BR_GATE && e_bflag))
            e_trap = TRAP_ILLEGAL;
        else if (e_c.priv && cur_pl != 2'd0)
            e_trap = TRAP_PRIV_OP;
        // assist emulation: ISR/IOR hold the data address of a coprocessor load or
        // store (ACD p.4-25, "valid only if the instruction is a coprocessor load
        // or store"); HP-UX emulates FP loads and stores with the FPU disabled
        // from them (its lazy FP context switch, $emulation_trap -> pa1_ldst)
        else if (e_c.assist) begin
            e_trap = TRAP_ASSIST_EM; e_trap_data = e_c.fpm;
        end else if ((e_c.fu == FU_FP || e_c.fpm) && ccr[7:6] != 2'b11) begin   // FPU disabled (ACD table 6-7)
            e_trap = TRAP_ASSIST_EM; e_trap_data = e_c.fpm;
        end
        else if ((e_c.fu == FU_FP || e_c.fpm) && fp_t && !e_fstd_fr0)  // delayed FP trap (sec. 3.5)
            e_trap = TRAP_ASSIST_EX;
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
            FU_LOAD, FU_STORE: if (e_unal) begin e_trap = TRAP_UNALIGNED; e_trap_data = 1'b1; end
            default: ;
        endcase
    end

    // ---- E redirect: resolve against the prediction
    wire e_mispred = e_is_branch && (e_taken != e_pred || (e_taken && e_pred && e_c.br == BR_GATE && gate_pl != 2'b00));
    wire e_redir = adv && e_mispred;
    assign redir          = e_redir || d_redir;
    assign redir_new_space = e_redir && e_taken && br_new_space;
    assign redir_slot_e   = e_iaoq_b;
    assign redir_slot_d   = d_iaoq_b;
    assign redir_from_e   = e_redir;
    assign redir_slot_in_d = e_redir && d_valid;
    assign redir_d        = d_redir;
    assign redir_d_target = d_target;

    // ================================================================ M stage
    // TLB lookup: the instruction in M when it translates, else the fetch unit's refill
    wire m_is_data = m_c.fu == FU_LOAD || m_c.fu == FU_STORE;
    wire m_is_wr   = m_c.fu == FU_STORE || m_c.ldcw || (m_c.fu == FU_MMU && m_c.sysop == MM_PDC);
    wire m_is_rd   = m_c.fu == FU_LOAD;
    wire m_probe   = m_c.fu == FU_MMU && m_c.sysop == MM_PROBE;
    wire m_lpa     = m_c.fu == FU_MMU && m_c.sysop == MM_LPA;
    // The CAM compare runs in E (cpu-timing.md 4.9): the TLB compares the next
    // tag -- E's virtual address when the instruction entering M translates,
    // else the I-LAB's request -- and registers the match at the E -> M edge
    // (or whenever the port is free for the I-LAB: a hold with nothing to
    // translate in M). M then starts from the registered match. The I-LAB is
    // served only while its request still equals the registered tag (a
    // redirect may have moved F1 since the edge).
    // (the tag select is E's own need, never the W hold: `adv` only gates
    // the load, so no W-stage control sits in front of the CAM -- 4.10)
    wire e_need = e_valid && !e_nul && e_xlate;
    assign tlb_lk_space = e_need ? e_sp : it_space;
    assign tlb_lk_vpn   = e_need ? e_va[31:12] : it_vpn;
    assign tlb_lk_load  = adv || !m_need;
    logic        lk_is_it;              // the registered match is the I-LAB's
    always_ff @(posedge clk) begin
        if (!rst_n) lk_is_it <= 1'b0;
        else if (tlb_op_accept) lk_is_it <= 1'b0;
        else if (tlb_lk_load) lk_is_it <= !e_need;
    end
    // every translation hit sets the entry's used bit (cpu.md 2.2), the
    // I-LAB's refills too: otherwise the code page's entry stays "not
    // recently used" while the LAB serves it and is the first replaced
    assign tlb_lk_use   = (m_need && adv) || it_ack;
    assign it_ack = it_req && lk_is_it && !m_need && !tlb_op_cam &&
                    {it_space, it_vpn} == tlb_lk_tag_r;
    assign it_hit = tlb_lk_hit;
    assign it_rpn = tlb_lk_rpn;
    assign it_type = tlb_lk_ar[6:4];
    // access rights (ACD table 3-1): type = ar 0:2, PL1 = ar 3:4, PL2 = ar 5:6
    wire [2:0] ar_type = tlb_lk_ar[6:4];
    wire [1:0] ar_pl1 = tlb_lk_ar[3:2], ar_pl2 = tlb_lk_ar[1:0];
    wire [1:0] chk_pl = m_probe ? m_ppl : m_pl;
    wire rd_ok = !ar_type[2] && chk_pl <= ar_pl1;
    wire wr_ok = (ar_type == 3'd1 || ar_type == 3'd3) && chk_pl <= ar_pl2;
    function automatic logic xok_at(input logic [1:0] pl);
        return ar_type[2:1] != 2'b00 && ar_pl2 <= pl && pl <= ar_pl1;
    endfunction
    // the PID match comes with the entry (pa_tlb computes it per entry from
    // the PID registers); PSW[P] = 0 disables the check
    wire pid_rd_ok = !psw[P_P] || tlb_lk_pid_rd;
    wire pid_wr_ok = !psw[P_P] || tlb_lk_pid_wr;
    always_comb for (int k = 0; k < 4; k++) pid_o[k] = pid[k][15:0];
    assign it_xok = {xok_at(2'd3), xok_at(2'd2), xok_at(2'd1), xok_at(2'd0)} & {4{pid_rd_ok}};
    wire [19:0] m_rpn = m_xlate ? tlb_lk_rpn : m_ea[31:12];
    wire m_tmiss = m_xlate && !tlb_lk_hit;
    wire m_io    = m_rpn[19:16] == 4'hF;
    wire m_cached_c = !m_io && !(m_xlate && tlb_lk_u);
    assign dc_m_rpn = m_rpn;
    // the group-3 data traps of this access (ACD p.4-14 order), merged with E's
    logic [5:0] m_trap_x;
    logic       m_trap_xd;
    always_comb begin
        m_trap_x = m_trap; m_trap_xd = m_trap_data;
        if (m_xlate && !m_nul) begin
            if (m_tmiss)                                   begin m_trap_x = (m_is_data) ? TRAP_DTLB : TRAP_NA_DTLB; m_trap_xd = 1'b1; end
            else if (!m_probe && !m_lpa) begin
                if ((m_is_rd && !rd_ok) || (m_is_wr && !wr_ok))        begin m_trap_x = 6'd26; m_trap_xd = 1'b1; end
                else if ((m_is_rd && !pid_rd_ok) || (m_is_wr && !pid_wr_ok)) begin m_trap_x = 6'd27; m_trap_xd = 1'b1; end
                else if (m_trap != TRAP_NONE) ;
                else if (m_is_wr && tlb_lk_b && !psw[P_X])            begin m_trap_x = 6'd19; m_trap_xd = 1'b1; end
                else if (m_is_wr && !tlb_lk_d)                         begin m_trap_x = 6'd20; m_trap_xd = 1'b1; end
                else if (m_is_data && tlb_lk_t)                        begin m_trap_x = 6'd21; m_trap_xd = 1'b1; end
            end
        end
    end
    wire m_walk_ok = m_tmiss && !dr25[0];                 // DR25 bit 31: D walker disabled
    logic [31:0] m_result2;
    always_comb begin
        m_result2 = m_result;
        if (m_c.fu == FU_SYS && m_c.sysop == SYS_LDSID) m_result2 = {16'd0, m_space};
        else if (m_probe) m_result2 = {31'd0, (m_c.probe_w ? (wr_ok && pid_wr_ok) : (rd_ok && pid_rd_ok))};
        else if (m_lpa)   m_result2 = {m_rpn, m_ea[11:0]};
        else if (m_c.fu == FU_MMU && m_c.sysop == MM_LCI) m_result2 = 32'd0;
    end
    // cached data: the doubleword from the D-cache (with store forwarding), the
    // load word aligned, the store lanes merged for the W write-back
    wire [31:0] m_word = m_ea[2] ? dc_m_rdata[31:0] : dc_m_rdata[63:32];
    logic [31:0] m_ld;
    always_comb case (m_c.size)
        2'd0:    m_ld = {24'd0, m_word[8 * (3 - m_ea[1:0]) +: 8]};
        2'd1:    m_ld = {16'd0, m_ea[1] ? m_word[15:0] : m_word[31:16]};
        default: m_ld = m_word;
    endcase
    logic [63:0] m_stdw;
    wire [7:0] m_lanes = (m_c.size == 2'd3) ? 8'hFF : m_ea[2] ? {4'b0000, m_be} : {m_be, 4'b0000};   // [7] = byte 0
    always_comb
        for (int b = 0; b < 8; b++)
            m_stdw[63 - 8*b -: 8] = m_lanes[7 - b] ? m_stdata[31 - 8*(b & 3) -: 8] : dc_m_rdata[63 - 8*b -: 8];

    // ================================================================ W stage
    wire [1:0] w_pl = w_iaoq_f[1:0];
    wire w_is_mem   = w_c.fu == FU_LOAD || w_c.fu == FU_STORE;
    wire w_is_load  = w_c.fu == FU_LOAD;
    wire w_is_cmem  = w_is_mem && w_cached;          // a cacheable data access
    wire w_is_sync  = w_c.fu == FU_SYS && w_c.sysop == SYS_SYNC;
    wire w_is_rfi   = w_c.fu == FU_SYS && (w_c.sysop == SYS_RFI || w_c.sysop == SYS_RFIR);
    wire w_flush    = (w_c.fu == FU_SYS && (w_c.sysop == SYS_RFI || w_c.sysop == SYS_RFIR ||
                       w_c.sysop == SYS_SSM || w_c.sysop == SYS_RSM || w_c.sysop == SYS_MTSM)) ||
                      w_c.fu == FU_DIAG || w_c.fu == FU_MMU || w_opflush;
    // which cache engine, if any, an instruction in W uses
    wire w_dc_op = w_c.fu == FU_MMU && (w_c.sysop == MM_FDC || w_c.sysop == MM_FDCE || w_c.sysop == MM_PDC) ||
                   w_c.fu == FU_DIAG && (w_c.sysop == DG_RDD || w_c.sysop == DG_RDT || w_c.sysop == DG_RDTLB ||
                                         w_c.sysop == DG_WDD || w_c.sysop == DG_WDT);
    wire w_ic_op = w_c.fu == FU_MMU && (w_c.sysop == MM_FIC || w_c.sysop == MM_FICE) ||
                   w_c.fu == FU_DIAG && (w_c.sysop == DG_RI2D || w_c.sysop == DG_RI2T || w_c.sysop == DG_WI2D ||
                                         w_c.sysop == DG_WI2T || w_c.sysop == DG_RI1 || w_c.sysop == DG_WI1);
    wire w_diag_rd = w_c.fu == FU_DIAG && (w_c.sysop == DG_RDD || w_c.sysop == DG_RDT || w_c.sysop == DG_RDTLB ||
                                           w_c.sysop == DG_RI2D || w_c.sysop == DG_RI2T);
    wire w_tlb_op = w_c.fu == FU_MMU && (w_c.sysop == MM_TLB_INS || w_c.sysop == MM_TLB_PURGE);
    // cache parity errors of the instruction in W: its own fetch, or its data access
    wire [3:0] w_dperr_eff = (w_is_cmem && w_hit) ? w_dperr : 4'd0;
    // cache parity flags {dirty, tag, odd word, even word} -> DR0 L2PARERR bits 15:12 (= dr0[16:19])
    function automatic logic [3:0] perr_dr0(input logic [3:0] p); return {p[0], p[1], p[2], p[3]}; endfunction
    wire w_l2i_err = |w_fperr[1:0], w_l1i_err = |w_fperr[3:2], w_l2d_err = |w_dperr_eff;
    wire hpmc_cache = (dr0[25] & ~dr0[24]) | (dr0[23] & ~dr0[22]) | (dr0[21] & ~dr0[20]) |
                      (w_valid && ((w_l2i_err & ~dr0[24]) | (w_l1i_err & ~dr0[20]) | (w_l2d_err & ~dr0[22])));
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
        else if (!psw[P_M] && (hpmc_req || hpmc_pend || hpmc_cache)) w_vec = TRAP_HPMC;
        else if (toc_pend && !toc_mask)                 w_vec = TRAP_TOC;
        else if (take_rctr)                             w_vec = TRAP_RCTR;
        else if (take_ext)                              w_vec = TRAP_EXT;
        else if (take_lpmc)                             w_vec = TRAP_LPMC;
        else if (!w_nul && w_trap != TRAP_NONE && !(w_trap == TRAP_HPMC && psw[P_M]) && !w_walkable_now) begin
            w_vec = w_trap; w_before = 1'b0;
        end
        if (w_valid && wst == W_WFAIL) begin w_vec = w_trap; w_before = 1'b0; end
    end
    wire w_run_trap = w_valid && wst == W_RUN && w_vec != TRAP_NONE;
    wire w_ld_trap  = w_valid && wst == W_DONE && w_lderr && !psw[P_M];
    wire w_wfail_trap = w_valid && wst == W_WFAIL;
    assign w_trap_take = w_run_trap || w_ld_trap || w_wfail_trap;
    logic w_walkable_now;

    // ---- data access from W
    // uncached (I/O space): the BIU port; cached: the D-cache, misses go to
    // the engine and the instruction is replayed
    wire w_mem_go  = w_exec && w_is_mem && wst == W_RUN && !w_run_trap && !w_walkable_now;
    wire w_umem_go = w_mem_go && !w_cached;
    wire w_cmem_go = w_mem_go && w_cached && dc_ready;
    // LDCW with a cache hint, or hitting a dirty line, is done in the cache; with
    // no hint the engine re-checks the line (cpu.md 5.7)
    wire w_ldcw_check = w_c.ldcw && w_c.cc == 2'd0;
    wire w_chit = w_hit && !(w_ldcw_check);
    always_comb begin
        d_req = 1'b0; d_we = 1'b0; d_rclr = 1'b0;
        d_addr = {w_rpn, w_ea[11:0]};                   // the physical address (translated in M)
        d_be = 8'd0;
        d_wdata = (w_c.fpm && w_c.size == 2'd3) ? fp_st_data :
                  w_c.fpm ? {fp_st_data[31:0], fp_st_data[31:0]} : {w_stdata, w_stdata};
        // loads too: an uncached byte read must not touch the neighbouring
        // registers of an I/O device (FIFO pops, read-to-clear; cpu-requests #3)
        if (w_c.size == 2'd3) d_be = 8'hFF;
        else                  d_be = w_ea[2] ? {4'b0000, w_be} : {w_be, 4'b0000};
        if (w_umem_go) begin
            d_req = 1'b1; d_we = (w_c.fu == FU_STORE); d_rclr = w_c.ldcw;
        end else if (wst == W_WAIT) begin
            d_req = 1'b1; d_rclr = w_c.ldcw;
        end
    end
    // load data formatting at the ack (uncached), or from the filled doubleword (a miss completing in W)
    wire [63:0] ld_src  = (wst == W_OP) ? dc_op_dw : d_rdata;
    wire [31:0] ld_word = w_ea[2] ? ld_src[31:0] : ld_src[63:32];
    // the store's lanes merged into the filled doubleword (the merge in M read the wrong line)
    wire [7:0] w_lanes = (w_c.size == 2'd3) ? 8'hFF : w_ea[2] ? {4'b0000, w_be} : {w_be, 4'b0000};
    logic [63:0] w_fill_stdw;
    always_comb
        for (int b = 0; b < 8; b++)
            w_fill_stdw[63 - 8*b -: 8] = w_lanes[7 - b] ? w_stdata[31 - 8*(b & 3) -: 8] : dc_op_dw[63 - 8*b -: 8];
    logic [31:0] ld_data;
    always_comb case (w_c.size)
        2'd0:    ld_data = {24'd0, ld_word[8 * (3 - w_ea[1:0]) +: 8]};
        2'd1:    ld_data = {16'd0, w_ea[1] ? ld_word[15:0] : ld_word[31:16]};
        default: ld_data = ld_word;
    endcase

    // ---- cache engines
    wire w_op_go = w_exec && wst == W_RUN && !w_run_trap && !w_walkable_now && (w_dc_op || w_ic_op || w_tlb_op);
    wire w_in_op = w_valid && wst == W_OP;
    logic [1:0] w_op_eng;                 // the current W_OP's engine: 0 D-cache, 1 I-cache, 2 TLB
    wire w_op_isd = w_op_eng == 2'd0;
    wire w_walking_rd = w_valid && (wst == W_WALK_RD || wst == W_WALK_RD3);
    wire w_walking_tlb = w_valid && (wst == W_WALK_A || wst == W_WALK_P);
    assign dc_op_req  = (w_in_op && w_op_isd && !dc_op_done) || (w_walking_rd && !dc_op_done);
    assign ic_op_req  = w_in_op && w_op_eng == 2'd1 && !ic_op_done;
    // the request, space and offset go to the TLB a cycle late, from registers:
    // the CAM compares the operation's tag in the cycle it accepts it, and
    // `w_walking_tlb` (w_valid, wst) in front of the 72-entry compare and its OR
    // tree was the core clock's worst path (fit 18, cpu-timing.md). The
    // operation starts one cycle later; W holds meanwhile
    wire tlb_op_req_c = (w_in_op && w_op_eng == 2'd2 && !tlb_op_done) || (w_walking_tlb && !tlb_op_done);
    logic        tlb_op_req_r;
    logic [15:0] tlb_op_space_r;
    logic [31:0] tlb_op_off_r;
    assign tlb_op_req = tlb_op_req_r;
    always_comb begin
        dc_op = DC_MISS;
        if (w_walking_rd) dc_op = DC_RD2;
        else if (w_is_mem) dc_op = w_ldcw_check ? DC_LDCW : DC_MISS;
        else case (w_c.sysop)
            MM_FDC:  dc_op = DC_FDC;
            MM_FDCE: dc_op = DC_FDCE;
            MM_PDC:  dc_op = (w_pl == 2'd0) ? DC_PDC : DC_FDC;
            DG_RDD, DG_RDTLB: dc_op = DC_RDD;
            DG_RDT:  dc_op = DC_RDT;
            DG_WDD:  dc_op = DC_WDD;
            DG_WDT:  dc_op = DC_WDT;
            default: ;
        endcase
        case (w_c.sysop)
            MM_FIC:  ic_op = IC_FIC;
            MM_FICE: ic_op = IC_FICE;
            DG_RI2D: ic_op = IC_RI2D;
            DG_RI2T: ic_op = IC_RI2T;
            DG_WI2D: ic_op = IC_WI2D;
            DG_WI2T: ic_op = IC_WI2T;
            DG_RI1:  ic_op = IC_RI1;
            default: ic_op = IC_WI1;
        endcase
    end
    // addresses for the engines: the walker reads the PDIR at a real address; FDCE /
    // FICE and the diagnose ops index by the plain address; the rest as translated in M
    wire w_plain = w_c.fu == FU_DIAG || (w_c.fu == FU_MMU && (w_c.sysop == MM_FDCE || w_c.sysop == MM_FICE));
    assign dc_op_addr  = w_walking_rd ? w_pdir_a : w_ea;
    assign dc_op_hash  = (w_walking_rd || w_plain) ? 5'd0 : w_hash;
    assign dc_op_rpn   = w_walking_rd ? w_pdir_a[31:12] : w_plain && !(w_c.sysop == DG_RDTLB) ? w_ea[31:12] : w_rpn;
    assign dc_op_wdata = (w_c.sysop == DG_WDT) ? set_tag : w_result;
    assign ic_op_addr  = (w_c.sysop == DG_RI1) ? iiaoq_b : w_ea;
    assign ic_op_hash  = w_plain ? 5'd0 : w_hash;
    assign ic_op_rpn   = w_plain ? w_ea[31:12] : w_rpn;
    assign ic_op_wdata = (w_c.sysop == DG_WI2T) ? set_tag : w_result;
    // store addressing: hashed index and RPN as translated in M
    assign dc_st_hash = w_hash;
    assign dc_st_rpn  = w_rpn;
    assign dc_st_fwd  = w_valid && !w_nul && w_is_cmem && (w_c.fu == FU_STORE || w_c.ldcw);
    // TLB operations: the instruction's own (VA from E, GR[r]) or the walker's inserts
    wire [31:0] pdir_w0 = dc_op_rd2[127:96], pdir_w1 = dc_op_rd2[95:64], pdir_w2 = dc_op_rd2[63:32], pdir_w3 = dc_op_rd2[31:0];
    wire w_walk_i = w_trap == TRAP_ITLB;                        // walking for a fetch miss
    wire [15:0] tlb_op_space_c = w_walking_tlb ? (w_walk_i ? w_iasq_f : w_space) : w_space;
    wire [31:0] tlb_op_off_c   = w_walking_tlb ? (w_walk_i ? w_iaoq_f : w_ea) : w_ea;
    always_ff @(posedge clk) begin
        if (!rst_n) begin tlb_op_req_r <= 1'b0; tlb_op_space_r <= 16'd0; tlb_op_off_r <= 32'd0; end
        else begin tlb_op_req_r <= tlb_op_req_c; tlb_op_space_r <= tlb_op_space_c; tlb_op_off_r <= tlb_op_off_c; end
    end
    assign tlb_op_space = tlb_op_space_r;
    assign tlb_op_off   = tlb_op_off_r;
    assign tlb_op_gr    = (wst == W_WALK_A) ? pdir_w2 : (wst == W_WALK_P) ? pdir_w1 : w_result;
    always_comb begin
        if (wst == W_WALK_A) tlb_op = TLB_INS_A;
        else if (wst == W_WALK_P) tlb_op = TLB_INS_P;
        else if (w_c.sysop == MM_TLB_PURGE) tlb_op = w_c.tlb_all ? TLB_PURGE_ALL : TLB_PURGE;
        else tlb_op = w_c.tlb_p ? TLB_INS_P : TLB_INS_A;
    end
    // the hardware walker (cpu.md 2.6): hashed PDIR entry address, checks, CR28 rule
    wire [15:0] wk_space = w_walk_i ? w_iasq_f : w_space;
    wire [31:0] wk_off   = w_walk_i ? w_iaoq_f : w_ea;
    wire [31:0] wk_hash  = ({12'd0, wk_off[31:12]} << 4) ^ ({16'd0, wk_space} << 9);
    wire [31:0] wk_addr  = (dr24 & 32'hFFFF_F000) | (wk_hash & (dr25 | 32'h0000_0FFF));
    wire wk_v = pdir_w0[31], wk_r = pdir_w1[31];
    wire wk_tag_ok = pdir_w0[30:16] == wk_off[31:17] && pdir_w0[15:0] == wk_space;
    wire wk_pass = wk_v && wk_r && wk_tag_ok;
    logic [31:0] wk_cr28;
    logic        w_cr28_we;             // the failed walk writes CR28 with the trap
    logic [31:0] w_cr28_val;
    always_comb begin
        if (!(wk_v && wk_r)) wk_cr28 = w_pdir_a;
        else if (!dr25[2])   wk_cr28 = w_pdir_a;                // DR25 bit 29 U = 0: the current entry
        else if (!dr25[1])   wk_cr28 = pdir_w3;                 // N = 0: this entry's next pointer
        else                 wk_cr28 = 32'd0;                   // N = 1: word3 of the line (read below)
    end
    // can this instruction's miss be walked?
    assign w_walkable_now = !w_nul && (((w_trap == TRAP_DTLB || w_trap == TRAP_NA_DTLB) && w_walk) ||
                                       (w_trap == TRAP_ITLB && !dr25[3]));
    wire w_walk_go = w_valid && wst == W_RUN && w_walkable_now && !w_run_trap;
    assign ic_dr27 = dr27; assign ic_dr28 = dr28; assign ic_dr29 = dr29;
    assign ic_l1_en = dr0[2];
    wire w_op_done = w_in_op && (w_op_eng == 2'd0 ? dc_op_done : w_op_eng == 2'd1 ? ic_op_done : tlb_op_done);
    // the cached access of the instruction in W completes in the cache this cycle
    wire w_cache_hit_go = w_cmem_go && w_chit;
    assign dc_st_we   = (w_cache_hit_go && (w_c.fu == FU_STORE || w_c.ldcw)) ||
                        (w_valid && wst == W_DONE && w_c.ldcw && w_cached && !w_lderr && w_opflush) ||
                        (w_valid && wst == W_DONE && (w_c.fu == FU_STORE || w_c.ldcw) && w_cached && !w_lderr && w_stfill);
    assign dc_st_addr = w_ea;
    // FP stores: the FR data replaces the store lanes merged in M (FSTD: all eight)
    assign dc_st_data = !w_c.fpm ? w_stdw :
                        (w_c.size == 2'd3) ? fp_st_data :
                        w_ea[2] ? {w_stdw[63:32], fp_st_data[31:0]} : {fp_st_data[31:0], w_stdw[31:0]};
    // ---- FP unit interface (sec. 6.11): everything happens at W commit, in order
    assign fp_issue     = w_commit && !w_nul && w_c.fu == FU_FP;
    assign fp_insn      = w_insn;
    assign fp_st_dbl    = w_c.size == 2'd3;
    assign fp_ld_we     = w_commit && !w_nul && w_c.fpm && w_c.fu == FU_LOAD;
    assign fp_ld_data   = w_ld;
    assign fp_st_commit = w_commit && !w_nul && w_c.fpm && w_c.fu == FU_STORE;

    // W holds while an access or an engine operation is in flight
    always_comb begin
        w_hold = 1'b0;
        if (w_valid) case (wst)
            W_RUN:  w_hold = (w_umem_go && (w_is_load || !d_ack)) ||
                             (w_mem_go && w_cached && (!dc_ready || !w_chit)) ||
                             w_op_go || w_walk_go ||
                             (w_exec && w_is_sync && !sb_empty && !w_run_trap);
            W_WAIT, W_OP, W_REPLAY, W_WALK_RD, W_WALK_RD3, W_WALK_A, W_WALK_P, W_WFAIL: w_hold = 1'b1;   // RD3: cpu-requests #5
            default: w_hold = 1'b0;
        endcase
    end
    // the instruction leaves W this cycle (commit or trap)
    assign w_commit = w_valid && !w_hold && !w_trap_take && wst != W_REPLAY && wst != W_WFAIL;
    wire w_replay = w_valid && wst == W_REPLAY;

    // ---- GR write ports
    // A load takes w_ld whether cached or not (cpu-timing.md 4.6): an uncached
    // load in W_RUN is held until its data lands in w_ld (W_DONE), and nothing
    // consumes wd0 while it is held, so the TLB's cached/uncached decision
    // (w_cached) stays out of the write-data select and the E forward.
    wire [31:0] w_wd0_val = (wst == W_DONE || w_is_load) ? w_ld[31:0] :
                            (w_c.fu == FU_SYS && (w_c.sysop == SYS_SSM || w_c.sysop == SYS_RSM)) ? {25'd0, psw[6:0]} :
                            w_result;
    always_comb begin
        we0 = w_commit && !w_nul && w_c.rt_we && w_c.rt != 0 && !(w_c.fu == FU_DIAG && w_diag_rd && wst != W_DONE);
        we1 = w_commit && !w_nul && w_c.base_we && w_c.rb != 0;
        wa0 = w_c.rt; wd0 = w_wd0_val;
        wa1 = w_c.rb; wd1 = w_base;
    end
    assign shr_restore = w_commit && !w_nul && ((w_c.fu == FU_SYS && w_c.sysop == SYS_RFIR) ||
                                                (w_c.fu == FU_DIAG && w_c.sysop == DG_SHDW_GR));
    assign shr_capture = w_trap_take || (w_commit && !w_nul && w_c.fu == FU_DIAG && w_c.sysop == DG_GR_SHDW);

    // ---- W redirect: trap, RFI, flush
    logic [31:0] psw_next;
    // a load that completed late (W_DONE) while E holds an instruction that
    // took its word from M: commit, then refetch from the next instruction
    wire w_refetch = wst == W_DONE && w_is_load && e_valid && e_bp_ld;
    assign w_redir = w_trap_take || (w_commit && !w_nul && (w_flush || w_refetch)) || w_replay;
    assign redir_kill_all = w_redir;
    // The I-LAB is refreshed only where the PCX-L refreshes its LAB (ERS s.6.4,
    // cpu.md 2.2): an interruption (the handler runs untranslated; the RFI
    // refills it), RFI, SSM/RSM/MTSM (the P bit), MTCTL to a PID, the ITLB
    // inserts and purges, DIAG (DR8). Not on the other redirects: a D-side
    // insert (IDTLBx, the walker's) or a cache miss replays the instruction
    // with the LAB kept. Dropping it there livelocked a full TLB -- the
    // walker's data-page insert evicted the code page, the refetch's insert
    // evicted the data page, and so on (HP-UX 10.20 pa_dma_init, cpu-requests #7).
    wire w_pid_wr = w_c.fu == FU_SYS && w_c.sysop == SYS_MTCTL &&
                    (w_c.cr == 5'd8 || w_c.cr == 5'd9 || w_c.cr == 5'd12 || w_c.cr == 5'd13);
    // every TLB insert/purge *instruction* refreshes it: the I and D forms are the same
    // operation on the unified TLB (ERS s.6.4 "the architected itlb instructions are
    // identical to the corresponding dtlb instructions"); the walker's inserts are not instructions
    wire w_itlb_op = w_c.fu == FU_MMU && (w_c.sysop == MM_TLB_INS || w_c.sysop == MM_TLB_PURGE);
    assign ilab_inval = w_trap_take ||
                        (w_commit && !w_nul && (w_c.fu == FU_SYS && (w_c.sysop == SYS_RFI || w_c.sysop == SYS_RFIR ||
                                                    w_c.sysop == SYS_SSM || w_c.sysop == SYS_RSM ||
                                                    w_c.sysop == SYS_MTSM) ||
                                                w_pid_wr || w_itlb_op || w_c.fu == FU_DIAG));
    wire [31:0] vec_addr = (w_vec == TRAP_HPMC || w_vec == TRAP_TOC) ? 32'hF000_0000 : {iva[31:10], w_vec[4:0], 5'd0};
    always_comb begin
        redir_back = 32'd0;
        if (w_trap_take)      begin redir_back = vec_addr + 32'd4; end
        else if (w_replay)    begin redir_back = w_iaoq_b; end
        else if (w_is_rfi)    begin redir_back = iiaoq_b; end
        else                  begin redir_back = w_iaoq_b + 32'd4; end
    end
    // the fetch state after a kill-all redirect: (front, back) and their spaces
    always_comb begin
        if (w_redir) begin
            if (w_trap_take)   begin redir_target = vec_addr; redir_space = 16'd0;    redir_back_space = 16'd0; end
            else if (w_replay) begin redir_target = w_iaoq_f; redir_space = w_iasq_f; redir_back_space = w_iasq_b; end
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
            d_valid <= 1'b0; e_valid <= 1'b0; m_valid <= 1'b0; w_valid <= 1'b0; m_need <= 1'b0;
            d_ferr <= 0; d_fperr <= 0; e_fperr <= 0; m_fperr <= 0; w_fperr <= 0; d_insn <= 0; d_iaoq_f <= 0; d_iaoq_b <= 0; d_iasq_f <= 0; d_iasq_b <= 0; d_target_r <= 0;
            e_nul <= 0; e_err <= 0; e_pred <= 0; e_bflag <= 0; e_insn <= 0; e_iaoq_f <= 0; e_iaoq_b <= 0; e_bp_ld_a <= 0; e_bp_ld_b <= 0;
            e_iasq_f <= 0; e_iasq_b <= 0; e_gra <= 0; e_grb <= 0; e_target <= 0; e_c <= '0;
            e_fa_sel <= 0; e_fb_sel <= 0; e_cb_sel <= 0; e_v_sel <= 0; e_sar_sel <= 0; e_bp_ld <= 0; e_sar_r <= 0;
            m_nul <= 0; m_err <= 0; m_taken <= 0; m_nullify <= 0; m_new_space <= 0; m_insn <= 0;
            m_iaoq_f <= 0; m_iaoq_b <= 0; m_iasq_f <= 0; m_iasq_b <= 0; m_result <= 0; m_base <= 0;
            m_ea <= 0; m_target <= 0; m_trap <= 0; m_trap_data <= 0; m_cb <= 0; m_v <= 0;
            m_be <= 0; m_stdata <= 0; m_c <= '0;
            w_nul <= 0; w_err <= 0; w_taken <= 0; w_nullify <= 0; w_new_space <= 0; w_insn <= 0;
            w_iaoq_f <= 0; w_iaoq_b <= 0; w_iasq_f <= 0; w_iasq_b <= 0; w_result <= 0; w_base <= 0;
            w_ea <= 0; w_target <= 0; w_trap <= 0; w_trap_data <= 0; w_cb <= 0; w_v <= 0; w_space <= 0;
            w_be <= 0; w_stdata <= 0; w_c <= '0; w_ld <= 0; w_lderr <= 0;
            w_cached <= 0; w_hit <= 0; w_dirty <= 0; w_dperr <= 0; w_stdw <= 0; w_opflush <= 0; w_stfill <= 0; w_op_eng <= 0;
            w_rpn <= 0; w_hash <= 0; w_walk <= 0; w_pdir_a <= 0; w_cr28_we <= 0; w_cr28_val <= 0;
            d_itlb <= 0; d_imp <= 0; d_type <= 0; e_itlb <= 0; e_imp <= 0; e_type <= 0;
            m_space <= 0; m_hash <= 0; m_pl <= 0; m_ppl <= 0; m_xlate <= 0;
            pending_nul <= 1'b0; prev_taken <= 1'b0;
        end else begin
            // ---- W redirect kills everything younger (and W leaves)
            if (w_redir) begin
                d_valid <= 1'b0; e_valid <= 1'b0; m_valid <= 1'b0; w_valid <= 1'b0; m_need <= 1'b0;
                pending_nul <= psw_next[P_N];
                prev_taken  <= psw_next[P_B];
            end else begin
                // ---- M -> W, E -> M
                if (adv) begin
                    w_valid <= m_valid; w_nul <= m_nul; w_err <= m_err; w_taken <= m_taken;
                    w_nullify <= m_nullify; w_new_space <= m_new_space; w_insn <= m_insn;
                    w_iaoq_f <= m_iaoq_f; w_iaoq_b <= m_iaoq_b; w_iasq_f <= m_iasq_f; w_iasq_b <= m_iasq_b;
                    w_result <= m_result2; w_base <= m_base; w_ea <= m_ea; w_target <= m_target;
                    w_trap <= m_trap_x; w_trap_data <= m_trap_xd; w_cb <= m_cb; w_v <= m_v;
                    w_space <= m_space; w_be <= m_be; w_stdata <= m_stdata; w_c <= m_c;
                    w_fperr <= m_fperr; w_cached <= m_cached_c; w_hit <= dc_m_hit; w_dirty <= dc_m_dirty;
                    w_dperr <= dc_m_perr; w_stdw <= m_stdw; w_opflush <= 1'b0; w_stfill <= 1'b0;
                    w_rpn <= m_rpn; w_hash <= m_hash; w_walk <= m_walk_ok;
                    w_ld <= (m_c.size == 2'd3) ? dc_m_rdata : {32'd0, m_ld};   // an uncached load overwrites it at its ack

                    m_valid <= e_valid; m_nul <= e_nul; m_err <= e_err; m_taken <= e_taken;
                    m_nullify <= e_nullify; m_new_space <= e_taken && br_new_space; m_insn <= e_insn;
                    m_iaoq_f <= e_iaoq_f; m_iaoq_b <= e_iaoq_b; m_iasq_f <= e_iasq_f; m_iasq_b <= e_iasq_b;
                    m_result <= e_result; m_base <= ls_new_base; m_ea <= e_va; m_target <= br_target;
                    m_trap <= e_trap; m_trap_data <= e_trap_data; m_cb <= alu_cb; m_v <= alu_v;
                    m_be <= ls_be; m_stdata <= ls_wd_eff; m_c <= e_c;
                    m_fperr <= e_fperr;
                    m_space <= e_sp; m_hash <= e_hash; m_pl <= cur_pl; m_xlate <= e_xlate;
                    m_need <= e_valid && !e_nul && e_xlate;
                    m_ppl <= e_c.a_imm ? e_c.imm[1:0] : fa[1:0];
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
                        e_err <= d_ferr; e_fperr <= d_fperr; e_insn <= d_insn; e_iaoq_f <= d_iaoq_f;
                        e_itlb <= d_itlb; e_imp <= d_imp; e_type <= d_type;
                        e_iaoq_b <= (e_redir && d_valid) ? redir_target : d_iaoq_b;
                        e_iasq_f <= d_iasq_f;
                        e_iasq_b <= (e_redir && d_valid && redir_new_space) ? redir_space : d_iasq_b;
                        e_gra <= gra_d; e_grb <= grb_d; e_target <= d_target; e_c <= dc;
                        e_pred <= d_pred;
                        e_fa_sel <= fsel(dc.ra); e_fb_sel <= fsel(dc.rb);
                        e_bp_ld <= bp_ld_a || bp_ld_b; e_bp_ld_a <= bp_ld_a; e_bp_ld_b <= bp_ld_b; e_sar_r <= d_sar;
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
                    d_insn <= f2_insn; d_ferr <= f2_err; d_fperr <= f2_perr;
                    d_itlb <= f2_itlb; d_imp <= f2_imp; d_type <= f2_type;
                    d_iaoq_f <= f2_iaoq_f; d_iasq_f <= f2_iasq_f; d_target_r <= f2_target;
                    d_iaoq_b <= d_redir ? d_target : f2_iaoq_b;   // the F2 instruction is D's delay slot
                    d_iasq_b <= f2_iasq_b;
                    if (e_redir) begin
                        // E's delay slot: D's instruction if D held one, else the one
                        // entering from F2; anything else is the wrong path
                        if (!d_valid && f2_valid && f2_iaoq_f == e_iaoq_b) begin
                            d_iaoq_b <= redir_target;
                            if (redir_new_space) d_iasq_b <= redir_space;
                        end else
                            d_valid <= 1'b0;
                    end
                end
            end
            // ---- W state, the load data, the engine results
            if (!w_valid || w_commit || w_trap_take || w_replay) begin wst <= W_RUN; w_cr28_we <= 1'b0; end
            else if (wst == W_RUN) begin
                if (w_walk_go) begin wst <= W_WALK_RD; w_pdir_a <= wk_addr; end
                else if (w_umem_go && w_is_load) wst <= W_WAIT;
                else if (w_cmem_go && !w_chit) begin wst <= W_OP; w_op_eng <= 2'd0; end
                else if (w_op_go) begin wst <= W_OP; w_op_eng <= w_dc_op ? 2'd0 : w_ic_op ? 2'd1 : 2'd2; end
            end
            else if (wst == W_WALK_RD && dc_op_done) begin
                w_cr28_we <= 1'b1;
                if (dc_op_err) begin wst <= W_WFAIL; w_cr28_val <= w_pdir_a; end
                else if (wk_pass) begin wst <= W_WALK_A; w_cr28_we <= 1'b0; end
                else if (wk_v && wk_r && dr25[2] && dr25[1]) begin
                    // N = 1: word3 of the line, which an entry at word4 has 16 bytes below it
                    if (!w_pdir_a[4]) begin wst <= W_WFAIL; w_cr28_val <= pdir_w3; end
                    else begin wst <= W_WALK_RD3; w_pdir_a <= {w_pdir_a[31:5], 5'd0}; end
                end else begin wst <= W_WFAIL; w_cr28_val <= wk_cr28; end
            end
            else if (wst == W_WALK_RD3 && dc_op_done) begin wst <= W_WFAIL; w_cr28_val <= pdir_w3; end
            else if (wst == W_WALK_A && tlb_op_done) wst <= W_WALK_P;
            else if (wst == W_WALK_P && tlb_op_done) wst <= W_REPLAY;
            else if (wst == W_WAIT && d_ack) begin
                wst <= W_DONE; w_ld <= (w_c.size == 2'd3) ? d_rdata : {32'd0, ld_data}; w_lderr <= d_err;
                // the consumer in E took the (wrong) word from M: give it the real one instead of refetching it
                if (e_valid && e_bp_ld_a) e_gra <= ld_data;
                if (e_valid && e_bp_ld_b) e_grb <= ld_data;
                if (e_valid) e_bp_ld <= 1'b0;
            end
            else if (wst == W_OP && w_op_done) begin
                if (w_is_mem) begin
                    if (dc_op == DC_LDCW) begin
                        // in the cache if the line is dirty (the word read in M, cleared
                        // here); otherwise the line was invalidated: read-and-clear memory
                        w_opflush <= 1'b1;
                        if (dc_op_hit) begin wst <= W_DONE; w_lderr <= 1'b0; end
                        else begin wst <= W_WAIT; w_cached <= 1'b0; end
                    end else if (dc_op_err) begin wst <= W_DONE; w_lderr <= 1'b1; end
                    else begin
                        // the line is in: complete the access here (no replay, cpu.md 6.6): a load
                        // takes its word from the filled doubleword, a store writes its merged
                        // doubleword at W_DONE; a consumer in E that took the word from M is refetched
                        wst <= W_DONE; w_lderr <= 1'b0; w_stfill <= 1'b1;
                        w_ld <= (w_c.size == 2'd3) ? dc_op_dw : {32'd0, ld_data};
                        w_stdw <= w_c.fpm ? dc_op_dw : w_fill_stdw;
                        if (e_valid && e_bp_ld_a) e_gra <= ld_data;
                        if (e_valid && e_bp_ld_b) e_grb <= ld_data;
                        if (e_valid) e_bp_ld <= 1'b0;
                    end
                end else begin
                    wst <= W_DONE; w_lderr <= 1'b0;
                    if (w_diag_rd) w_ld <= {32'd0, w_op_isd ? dc_op_rdata : ic_op_rdata};
                end
            end
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
            set_tag <= 32'd0;
            toc_mask <= 1'b1; toc_pend <= 1'b0; hpmc_pend <= 1'b0;
            g4_pend <= 1'b0; g4_vec <= 0;
            dbg_retire <= 0; dbg_nullified <= 0; dbg_trap <= 0; dbg_trap_vec <= 0; dbg_iaoq_f <= 0;
            dbg_iaoq_b <= 0; dbg_iasq_f <= 0; dbg_insn <= 0; dbg_halted <= 0;
            dbg_gr_we <= 0; dbg_gr_num0 <= 0; dbg_gr_num1 <= 0; dbg_gr_data0 <= 0; dbg_gr_data1 <= 0;
            dbg_ea <= 0; dbg_stdata <= 0; dbg_wev <= 0; dbg_wev_iaoq <= 0; dbg_wev_ea <= 0;
        end else begin
            dbg_retire <= 1'b0; dbg_nullified <= 1'b0; dbg_trap <= 1'b0; dbg_halted <= 1'b0;
            dbg_wev <= (w_valid && wst == W_RUN && w_walk_go) ? 2'd2 : (w_cmem_go && !w_chit) ? 2'd1 : w_replay ? 2'd3 : 2'd0;
            dbg_wev_iaoq <= w_iaoq_f; dbg_wev_ea <= w_ea;
            dbg_gr_we <= {we1, we0}; dbg_gr_num0 <= wa0; dbg_gr_num1 <= wa1;
            dbg_gr_data0 <= wd0; dbg_gr_data1 <= wd1;

            // asynchronous requests
            if (cr16_match) eirr[31] <= 1'b1;
            if (eir_set) eirr[31 - eir_num] <= 1'b1;
            if (toc_req) toc_pend <= 1'b1;
            if (sb_err) hpmc_pend <= 1'b1;
            dr25[31] <= soft_pwr_n;                          // DR25 bit 0 (PA numbering)
            // cache parity flags (DR0 bits 6/8/10 and 12:15, PA numbering) from the
            // instruction's own fetch or data access, and HIT/PARERR from diagnose reads
            if (w_valid && wst == W_RUN) begin
                if (w_l2i_err) begin dr0[25] <= 1'b1; dr0[19:16] <= dr0[19:16] | perr_dr0({2'b00, w_fperr[1:0]}); end
                if (w_l1i_err) dr0[21] <= 1'b1;
                if (w_l2d_err) begin dr0[23] <= 1'b1; dr0[19:16] <= dr0[19:16] | perr_dr0(w_dperr_eff); end
            end
            if (w_op_done && w_diag_rd) begin
                dr0[1] <= w_op_isd ? dc_op_hit : ic_op_hit;
                dr0[0] <= |(w_op_isd ? dc_op_perr : ic_op_perr);
                if (w_op_isd && |dc_op_perr) begin dr0[23] <= 1'b1; dr0[19:16] <= dr0[19:16] | perr_dr0(dc_op_perr); end
                if (!w_op_isd && |ic_op_perr) begin dr0[25] <= 1'b1; dr0[19:16] <= dr0[19:16] | perr_dr0(ic_op_perr); end
            end
            if (w_op_done && w_c.fu == FU_DIAG && w_c.sysop == DG_RI1) begin
                dr27 <= ic_rd_dr27; dr28 <= ic_rd_dr28; dr29 <= ic_rd_dr29;
                dr0[1] <= ic_op_hit; dr0[0] <= |ic_op_perr;
                if (|ic_op_perr) dr0[21] <= 1'b1;
            end

            if (w_trap_take) begin
                enter_interruption(w_vec);
                if (w_wfail_trap && w_cr28_we) tr[4] <= w_cr28_val;
                dbg_trap <= 1'b1; dbg_trap_vec <= w_vec;
                dbg_iaoq_f <= w_iaoq_f; dbg_iaoq_b <= w_iaoq_b; dbg_iasq_f <= w_iasq_f; dbg_insn <= w_insn;
                dbg_ea <= w_ea; dbg_stdata <= w_stdata;
            end else if (w_commit) begin
                dbg_retire <= 1'b1; dbg_nullified <= w_nul;
                dbg_iaoq_f <= w_iaoq_f; dbg_iaoq_b <= w_iaoq_b; dbg_iasq_f <= w_iasq_f; dbg_insn <= w_insn;
                dbg_ea <= w_ea; dbg_stdata <= w_stdata;
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
                                // DR27-29 are declared with the pipeline registers
                                default: ;
                            endcase
                            DG_TOC_EN:  toc_mask <= 1'b0;
                            DG_TOC_DIS: toc_mask <= 1'b1;
                            DG_SET_TAG: set_tag <= w_result;
                            default: ;
                        endcase
                        default: ;
                    endcase
                end
            end
        end
    end
    assign dbg_psw = psw;
    assign psw_c_o = psw[P_C];
    assign dr8_o = dr8;
    assign ihash_o = {4'd0, dr0[3]};                     // DR0 IHASH_EN
endmodule
