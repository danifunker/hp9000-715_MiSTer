// PA-7100LC CPU top: the ports of docs/design/cpu.md 6.8 around the fetch
// unit, the pipeline core, the two caches and the bus interface unit.
module pa_cpu
    import pa_pkg::*;
#(
    parameter logic [5:0] CPU_REVISION = 6'd2      // DR0 bits 0:5 (user, 2026-10-07: 1..0xB; cpu-requests #2)
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [15:0] cfg_tq, cfg_tr, cfg_td,
    // cacheable line port (unused yet)
    output logic        mem_req, mem_we, mem_ifill,
    output logic [31:0] mem_addr,
    input  logic        mem_ack,
    output logic [63:0] mem_wdata,
    output logic        mem_wvalid,
    input  logic        mem_wready,
    input  logic [63:0] mem_rdata,
    input  logic        mem_rvalid,
    input  logic [1:0]  mem_rbeat,
    input  logic        mem_rerr,
    // uncached port
    output logic        io_req, io_we,
    output logic [31:0] io_addr,
    output logic [7:0]  io_be,
    output logic [63:0] io_wdata,
    output logic        io_ifetch, io_burst, io_rclr,
    input  logic        io_ack, io_last,
    input  logic [63:0] io_rdata,
    input  logic        io_err,
    // interrupts
    input  logic        eir_set,
    input  logic [4:0]  eir_num,
    input  logic        toc_req, hpmc_req, lpmc_req, powerfail,
    input  logic        soft_pwr_n,
    // debug taps
    output logic        dbg_retire, dbg_nullified,
    output logic [31:0] dbg_iaoq_f, dbg_iaoq_b,
    output logic [15:0] dbg_iasq_f,
    output logic [31:0] dbg_insn,
    output logic        dbg_trap,
    output logic [5:0]  dbg_trap_vec,
    output logic [1:0]  dbg_gr_we,
    output logic [4:0]  dbg_gr_num0, dbg_gr_num1,
    output logic [31:0] dbg_gr_data0, dbg_gr_data1,
    output logic [31:0] dbg_ea, dbg_stdata,            // cpu-requests #10 taps (pa_core)
    output logic [1:0]  dbg_wev,
    output logic [31:0] dbg_wev_iaoq, dbg_wev_ea,
    output logic [31:0] dbg_psw,
    output logic        dbg_halted,
    output logic        dbg_fp_stall,
    output logic [31:0] dbg_gr [32],
    // cache maintenance as the caches finish it (the board's event recorder):
    // FDC/FDCE/PDC (dbg_cop_i = 0) or FIC/FICE (1), the VA and the physical
    // page the line was compared against
    output logic        dbg_cop_valid,
    output logic        dbg_cop_i,
    output logic [3:0]  dbg_cop,
    output logic [31:0] dbg_cop_addr,
    output logic [19:0] dbg_cop_rpn
);
    // caches
    logic        dc_ready, dc_lk_en, dc_m_hit, dc_m_dirty, dc_st_we, dc_op_req, dc_op_done, dc_op_err, dc_op_hit;
    logic [31:0] dc_lk_addr, dc_m_addr, dc_st_addr, dc_op_addr, dc_op_wdata, dc_op_rdata;
    logic [63:0] dc_m_rdata, dc_st_data;
    logic [3:0]  dc_m_perr, dc_op_perr;
    dc_op_e      dc_op;
    logic        ic_ready, ic_lk_en, ic_lk_valid, ic_busy, ic_hit, ic_fill_req, ic_fill_done, ic_fill_err;
    logic        ic_op_req, ic_op_done, ic_op_hit, ic_l1_en;
    logic [31:0] ic_lk_addr, ic_word, ic_fill_addr, ic_op_addr, ic_op_wdata, ic_op_rdata;
    logic [31:0] ic_dr27, ic_dr28, ic_dr29, ic_rd_dr27, ic_rd_dr28, ic_rd_dr29;
    logic [3:0]  ic_perr, ic_op_perr;
    ic_op_e      ic_op;
    logic [31:0] ic_f1_addr;
    logic [4:0]  ic_lk_hash, ic_fill_hash, ic_op_hash, dc_lk_hash, dc_st_hash, dc_op_hash, ihash;
    logic [19:0] ic_f1_rpn, ic_fill_rpn, ic_op_rpn, dc_m_rpn, dc_st_rpn, dc_op_rpn;
    logic        dc_st_fwd, psw_c, f2_itlb, f2_imp;
    logic [2:0]  f2_type;
    logic [127:0] dc_op_rd2;
    logic [63:0]  dc_op_dw;
    logic [4:0]   dc_m_hash;
    // TLB
    logic [15:0] tlb_lk_space, tlb_op_space, it_space;
    logic [19:0] tlb_lk_vpn, tlb_lk_rpn, it_vpn, it_rpn;
    logic        tlb_lk_use, tlb_lk_hit, tlb_lk_t, tlb_lk_d, tlb_lk_b, tlb_lk_u, tlb_op_req, tlb_op_done, tlb_op_cam;
    logic        tlb_lk_load, tlb_op_accept, tlb_lk_pid_rd, tlb_lk_pid_wr;
    logic [15:0] pid_regs [4];
    logic [35:0] tlb_lk_tag_r;
    logic [6:0]  tlb_lk_ar;
    logic [14:0] tlb_lk_aid;
    tlb_op_e     tlb_op;
    logic [31:0] tlb_op_off, tlb_op_gr;
    logic        it_req, it_ack, it_hit;
    logic        fp_issue, fp_ld_we, fp_st_commit, fp_busy, fp_t;
    logic [31:0] fp_insn, fpsr;
    logic        fp_st_dbl;
    logic [63:0] fp_ld_data, fp_st_data;
    logic [31:0] dr8;
    logic [3:0]  it_xok;
    logic [2:0]  it_type;
    // line clients
    logic        dl_req, dl_we, dl_ack, dl_wvalid, dl_wready, dl_rvalid, dl_rerr;
    logic [31:0] dl_addr;
    logic [63:0] dl_wdata, dl_rdata;
    logic [1:0]  dl_rbeat;
    logic        il_req, il_ack, il_rvalid, il_rerr;
    logic [31:0] il_addr;
    logic [63:0] il_rdata;
    logic [1:0]  il_rbeat;

    logic        f2_valid, f2_err, adv_f2, drained, uib_inval;
    logic [31:0] f2_insn, f2_iaoq_f, f2_iaoq_b;
    logic [15:0] f2_iasq_f, f2_iasq_b;
    logic        redir, redir_kill_all, ilab_inval, redir_new_space;
    logic [31:0] redir_target, redir_back, redir_slot_e, redir_slot_d;
    logic        redir_from_e, redir_slot_in_d;
    logic [15:0] redir_space, redir_back_space;
    logic        f_req, f_beat, f_done, f_err;
    logic [31:0] f_addr;
    logic [1:0]  f_beat_idx;
    logic [63:0] f_data;
    logic        d_req, d_we, d_rclr, d_ack, d_err, sb_empty, sb_err, sb_valid;
    logic [31:0] d_addr, sb_addr;
    logic [7:0]  d_be;
    logic [63:0] d_wdata, d_rdata;

    pa_fetch u_fetch (
        .clk(clk), .rst_n(rst_n), .adv_f2(adv_f2), .drained(drained), .uib_inval(uib_inval),
        .psw_c(psw_c), .ihash(ihash),
        .it_req(it_req), .it_space(it_space), .it_vpn(it_vpn), .it_ack(it_ack), .it_hit(it_hit), .it_rpn(it_rpn),
        .it_xok(it_xok), .it_type(it_type),
        .redir(redir), .redir_kill_all(redir_kill_all), .ilab_inval(ilab_inval), .redir_target(redir_target), .redir_back(redir_back),
        .redir_space(redir_space), .redir_back_space(redir_back_space), .redir_new_space(redir_new_space),
        .redir_slot_e(redir_slot_e), .redir_slot_d(redir_slot_d), .redir_from_e(redir_from_e), .redir_slot_in_d(redir_slot_in_d),
        .f2_valid(f2_valid), .f2_insn(f2_insn), .f2_iaoq_f(f2_iaoq_f), .f2_iaoq_b(f2_iaoq_b),
        .f2_iasq_f(f2_iasq_f), .f2_iasq_b(f2_iasq_b), .f2_err(f2_err), .f2_perr(f2_perr),
        .f2_itlb(f2_itlb), .f2_imp(f2_imp), .f2_type(f2_type),
        .ic_lk_en(ic_lk_en), .ic_lk_addr(ic_lk_addr), .ic_lk_hash(ic_lk_hash), .ic_f1_addr(ic_f1_addr), .ic_f1_rpn(ic_f1_rpn),
        .ic_lk_valid(ic_lk_valid), .ic_busy(ic_busy),
        .ic_word(ic_word), .ic_hit(ic_hit), .ic_perr(ic_perr), .ic_fill_req(ic_fill_req),
        .ic_fill_addr(ic_fill_addr), .ic_fill_hash(ic_fill_hash), .ic_fill_rpn(ic_fill_rpn),
        .ic_fill_done(ic_fill_done), .ic_fill_err(ic_fill_err),
        .f_req(f_req), .f_addr(f_addr), .f_beat(f_beat), .f_beat_idx(f_beat_idx), .f_data(f_data),
        .f_done(f_done), .f_err(f_err));
    logic [3:0] f2_perr;

    pa_icache u_icache (
        .clk(clk), .rst_n(rst_n), .ready(ic_ready), .busy(ic_busy), .l1_en(ic_l1_en),
        .lk_en(ic_lk_en), .lk_addr(ic_lk_addr), .lk_hash(ic_lk_hash), .f1_addr(ic_f1_addr), .f1_rpn(ic_f1_rpn),
        .lk_valid(ic_lk_valid),
        .f1_word(ic_word), .f1_hit(ic_hit), .f1_perr(ic_perr), .f1_l1hit(),
        .fill_req(ic_fill_req), .fill_addr(ic_fill_addr), .fill_hash(ic_fill_hash), .fill_rpn(ic_fill_rpn),
        .fill_done(ic_fill_done), .fill_err(ic_fill_err),
        .op_req(ic_op_req), .op(ic_op), .op_addr(ic_op_addr), .op_hash(ic_op_hash), .op_rpn(ic_op_rpn), .op_wdata(ic_op_wdata),
        .dr27(ic_dr27), .dr28(ic_dr28), .dr29(ic_dr29), .op_done(ic_op_done), .op_hit(ic_op_hit),
        .op_perr(ic_op_perr), .op_rdata(ic_op_rdata), .rd_dr27(ic_rd_dr27), .rd_dr28(ic_rd_dr28), .rd_dr29(ic_rd_dr29),
        .ln_req(il_req), .ln_addr(il_addr), .ln_ack(il_ack), .ln_rdata(il_rdata), .ln_rvalid(il_rvalid),
        .ln_rbeat(il_rbeat), .ln_rerr(il_rerr));

    pa_dcache u_dcache (
        .clk(clk), .rst_n(rst_n), .ready(dc_ready),
        .lk_en(dc_lk_en), .lk_addr(dc_lk_addr), .lk_hash(dc_lk_hash), .m_addr(dc_m_addr), .m_hash(dc_m_hash), .m_rpn(dc_m_rpn),
        .m_rdata(dc_m_rdata), .m_hit(dc_m_hit), .m_dirty(dc_m_dirty), .m_perr(dc_m_perr),
        .st_we(dc_st_we), .st_fwd(dc_st_fwd), .st_addr(dc_st_addr), .st_hash(dc_st_hash), .st_rpn(dc_st_rpn), .st_data(dc_st_data),
        .op_req(dc_op_req), .op(dc_op), .op_addr(dc_op_addr), .op_hash(dc_op_hash), .op_rpn(dc_op_rpn),
        .op_wdata(dc_op_wdata), .op_rd2(dc_op_rd2), .op_dw(dc_op_dw), .op_done(dc_op_done),
        .op_err(dc_op_err), .op_hit(dc_op_hit), .op_perr(dc_op_perr), .op_rdata(dc_op_rdata),
        .ln_req(dl_req), .ln_we(dl_we), .ln_addr(dl_addr), .ln_ack(dl_ack), .ln_wdata(dl_wdata),
        .ln_wvalid(dl_wvalid), .ln_wready(dl_wready), .ln_rdata(dl_rdata), .ln_rvalid(dl_rvalid),
        .ln_rbeat(dl_rbeat), .ln_rerr(dl_rerr));

    pa_tlb u_tlb (
        .clk(clk), .rst_n(rst_n), .dr8(dr8),
        .lk_space(tlb_lk_space), .lk_vpn(tlb_lk_vpn), .lk_load(tlb_lk_load), .lk_tag_r(tlb_lk_tag_r),
        .lk_use(tlb_lk_use), .pid(pid_regs), .lk_hit(tlb_lk_hit), .lk_rpn(tlb_lk_rpn),
        .lk_ar(tlb_lk_ar), .lk_aid(tlb_lk_aid), .lk_pid_rd(tlb_lk_pid_rd), .lk_pid_wr(tlb_lk_pid_wr),
        .lk_t(tlb_lk_t), .lk_d(tlb_lk_d), .lk_b(tlb_lk_b), .lk_u(tlb_lk_u),
        .op_req(tlb_op_req), .op(tlb_op), .op_space(tlb_op_space), .op_off(tlb_op_off), .op_gr(tlb_op_gr),
        .op_done(tlb_op_done), .op_accept(tlb_op_accept), .op_cam(tlb_op_cam));

    pa_core #(.CPU_REVISION(CPU_REVISION)) u_core (
        .clk(clk), .rst_n(rst_n),
        .f2_valid(f2_valid), .f2_insn(f2_insn), .f2_iaoq_f(f2_iaoq_f), .f2_iaoq_b(f2_iaoq_b),
        .f2_iasq_f(f2_iasq_f), .f2_iasq_b(f2_iasq_b), .f2_err(f2_err), .f2_perr(f2_perr),
        .f2_itlb(f2_itlb), .f2_imp(f2_imp), .f2_type(f2_type), .psw_c_o(psw_c), .ihash_o(ihash), .dr8_o(dr8),
        .adv_f2(adv_f2), .drained(drained), .uib_inval(uib_inval),
        .tlb_lk_space(tlb_lk_space), .tlb_lk_vpn(tlb_lk_vpn), .tlb_lk_load(tlb_lk_load), .tlb_lk_tag_r(tlb_lk_tag_r), .tlb_op_accept(tlb_op_accept),
        .tlb_lk_pid_rd(tlb_lk_pid_rd), .tlb_lk_pid_wr(tlb_lk_pid_wr), .pid_o(pid_regs), .tlb_lk_use(tlb_lk_use), .tlb_lk_hit(tlb_lk_hit),
        .tlb_lk_rpn(tlb_lk_rpn), .tlb_lk_ar(tlb_lk_ar), .tlb_lk_aid(tlb_lk_aid), .tlb_lk_t(tlb_lk_t),
        .tlb_lk_d(tlb_lk_d), .tlb_lk_b(tlb_lk_b), .tlb_lk_u(tlb_lk_u),
        .tlb_op_req(tlb_op_req), .tlb_op(tlb_op), .tlb_op_space(tlb_op_space), .tlb_op_off(tlb_op_off),
        .tlb_op_gr(tlb_op_gr), .tlb_op_done(tlb_op_done), .tlb_op_cam(tlb_op_cam),
        .fp_issue(fp_issue), .fp_insn(fp_insn), .fp_st_dbl(fp_st_dbl), .fp_ld_we(fp_ld_we), .fp_ld_data(fp_ld_data),
        .fp_st_commit(fp_st_commit), .fp_st_data(fp_st_data), .fp_busy(fp_busy), .fp_t(fp_t), .fpsr(fpsr),
        .it_req(it_req), .it_space(it_space), .it_vpn(it_vpn), .it_ack(it_ack), .it_hit(it_hit), .it_rpn(it_rpn),
        .it_xok(it_xok), .it_type(it_type),
        .dc_ready(dc_ready), .dc_lk_en(dc_lk_en), .dc_lk_addr(dc_lk_addr), .dc_m_addr(dc_m_addr),
        .dc_lk_hash(dc_lk_hash), .dc_st_hash(dc_st_hash), .dc_op_hash(dc_op_hash),
        .dc_m_rpn(dc_m_rpn), .dc_st_rpn(dc_st_rpn), .dc_op_rpn(dc_op_rpn), .dc_st_fwd(dc_st_fwd), .dc_op_rd2(dc_op_rd2), .dc_op_dw(dc_op_dw), .dc_m_hash(dc_m_hash),
        .dc_m_rdata(dc_m_rdata), .dc_m_hit(dc_m_hit), .dc_m_dirty(dc_m_dirty), .dc_m_perr(dc_m_perr),
        .dc_st_we(dc_st_we), .dc_st_addr(dc_st_addr), .dc_st_data(dc_st_data),
        .dc_op_req(dc_op_req), .dc_op(dc_op), .dc_op_addr(dc_op_addr), .dc_op_wdata(dc_op_wdata),
        .dc_op_done(dc_op_done), .dc_op_err(dc_op_err), .dc_op_hit(dc_op_hit), .dc_op_perr(dc_op_perr),
        .dc_op_rdata(dc_op_rdata),
        .ic_ready(ic_ready), .ic_op_req(ic_op_req), .ic_op(ic_op), .ic_op_addr(ic_op_addr),
        .ic_op_wdata(ic_op_wdata), .ic_op_hash(ic_op_hash), .ic_op_rpn(ic_op_rpn),
        .ic_dr27(ic_dr27), .ic_dr28(ic_dr28), .ic_dr29(ic_dr29),
        .ic_op_done(ic_op_done), .ic_op_hit(ic_op_hit), .ic_op_perr(ic_op_perr), .ic_op_rdata(ic_op_rdata),
        .ic_rd_dr27(ic_rd_dr27), .ic_rd_dr28(ic_rd_dr28), .ic_rd_dr29(ic_rd_dr29), .ic_l1_en(ic_l1_en),
        .redir(redir), .redir_kill_all(redir_kill_all), .ilab_inval(ilab_inval), .redir_target(redir_target), .redir_back(redir_back),
        .redir_space(redir_space), .redir_back_space(redir_back_space), .redir_new_space(redir_new_space),
        .redir_slot_e(redir_slot_e), .redir_slot_d(redir_slot_d), .redir_from_e(redir_from_e), .redir_slot_in_d(redir_slot_in_d),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_be(d_be), .d_wdata(d_wdata), .d_rclr(d_rclr),
        .d_ack(d_ack), .d_err(d_err), .d_rdata(d_rdata), .sb_empty(sb_empty), .sb_err(sb_err),
        .eir_set(eir_set), .eir_num(eir_num), .toc_req(toc_req), .hpmc_req(hpmc_req), .lpmc_req(lpmc_req),
        .powerfail(powerfail), .soft_pwr_n(soft_pwr_n), .cfg_tq(cfg_tq), .cfg_tr(cfg_tr), .cfg_td(cfg_td),
        .dbg_retire(dbg_retire), .dbg_nullified(dbg_nullified), .dbg_iaoq_f(dbg_iaoq_f), .dbg_iaoq_b(dbg_iaoq_b),
        .dbg_iasq_f(dbg_iasq_f), .dbg_insn(dbg_insn), .dbg_trap(dbg_trap), .dbg_trap_vec(dbg_trap_vec),
        .dbg_gr_we(dbg_gr_we), .dbg_gr_num0(dbg_gr_num0), .dbg_gr_num1(dbg_gr_num1),
        .dbg_gr_data0(dbg_gr_data0), .dbg_gr_data1(dbg_gr_data1),
        .dbg_ea(dbg_ea), .dbg_stdata(dbg_stdata), .dbg_wev(dbg_wev), .dbg_wev_iaoq(dbg_wev_iaoq), .dbg_wev_ea(dbg_wev_ea),
        .dbg_psw(dbg_psw), .dbg_halted(dbg_halted), .dbg_fp_stall(dbg_fp_stall),
        .dbg_gr(dbg_gr));

    always_comb begin
        dbg_cop_valid = 1'b0; dbg_cop_i = 1'b0;
        dbg_cop = dc_op; dbg_cop_addr = dc_op_addr; dbg_cop_rpn = dc_op_rpn;
        if (dc_op_done && (dc_op == DC_FDC || dc_op == DC_FDCE || dc_op == DC_PDC)) dbg_cop_valid = 1'b1;
        else if (ic_op_done && (ic_op == IC_FIC || ic_op == IC_FICE)) begin
            dbg_cop_valid = 1'b1; dbg_cop_i = 1'b1;
            dbg_cop = ic_op; dbg_cop_addr = ic_op_addr; dbg_cop_rpn = ic_op_rpn;
        end
    end

    pa_fpunit u_fpu (
        .clk(clk), .rst_n(rst_n),
        .issue(fp_issue), .insn(fp_insn), .st_dbl(fp_st_dbl), .ld_we(fp_ld_we), .ld_data(fp_ld_data),
        .st_commit(fp_st_commit), .st_data(fp_st_data), .busy(fp_busy), .fpsr_t(fp_t), .fpsr_o(fpsr));

    pa_biu u_biu (
        .clk(clk), .rst_n(rst_n),
        .io_req(io_req), .io_we(io_we), .io_addr(io_addr), .io_be(io_be), .io_wdata(io_wdata),
        .io_ifetch(io_ifetch), .io_burst(io_burst), .io_rclr(io_rclr), .io_ack(io_ack), .io_last(io_last),
        .io_rdata(io_rdata), .io_err(io_err),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_be(d_be), .d_wdata(d_wdata), .d_rclr(d_rclr),
        .d_ack(d_ack), .d_err(d_err), .d_rdata(d_rdata), .sb_empty(sb_empty), .sb_err(sb_err),
        .sb_valid_o(sb_valid), .sb_addr_o(sb_addr),
        .mem_req(mem_req), .mem_we(mem_we), .mem_ifill(mem_ifill), .mem_addr(mem_addr), .mem_ack(mem_ack),
        .mem_wdata(mem_wdata), .mem_wvalid(mem_wvalid), .mem_wready(mem_wready), .mem_rdata(mem_rdata),
        .mem_rvalid(mem_rvalid), .mem_rbeat(mem_rbeat), .mem_rerr(mem_rerr),
        .dl_req(dl_req), .dl_we(dl_we), .dl_addr(dl_addr), .dl_ack(dl_ack), .dl_wdata(dl_wdata),
        .dl_wvalid(dl_wvalid), .dl_wready(dl_wready), .dl_rdata(dl_rdata), .dl_rvalid(dl_rvalid),
        .dl_rbeat(dl_rbeat), .dl_rerr(dl_rerr),
        .il_req(il_req), .il_addr(il_addr), .il_ack(il_ack), .il_rdata(il_rdata), .il_rvalid(il_rvalid),
        .il_rbeat(il_rbeat), .il_rerr(il_rerr),
        .f_req(f_req), .f_addr(f_addr), .f_beat(f_beat), .f_beat_idx(f_beat_idx), .f_data(f_data),
        .f_done(f_done), .f_err(f_err));
endmodule
