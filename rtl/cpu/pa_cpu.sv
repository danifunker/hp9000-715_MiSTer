// PA-7100LC CPU top: the ports of docs/design/cpu.md 6.8 around the fetch
// unit, the pipeline core and the bus interface unit. The cacheable line
// port is tied off until the caches exist (STUBS S-005): every access goes
// out on the uncached port.
module pa_cpu
    import pa_pkg::*;
#(
    parameter logic [5:0] CPU_REVISION = 6'd0
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
    output logic [31:0] dbg_psw,
    output logic        dbg_halted,
    output logic [31:0] dbg_gr [32]
);
    assign mem_req = 1'b0; assign mem_we = 1'b0; assign mem_ifill = 1'b0; assign mem_addr = 32'd0;
    assign mem_wdata = 64'd0; assign mem_wvalid = 1'b0;

    logic        f2_valid, f2_err, adv_f2, drained, uib_inval;
    logic [31:0] f2_insn, f2_iaoq_f, f2_iaoq_b;
    logic [15:0] f2_iasq_f, f2_iasq_b;
    logic        redir, redir_kill_all, redir_new_space;
    logic [31:0] redir_target, redir_back, redir_slot;
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
        .redir(redir), .redir_kill_all(redir_kill_all), .redir_target(redir_target), .redir_back(redir_back),
        .redir_space(redir_space), .redir_back_space(redir_back_space), .redir_new_space(redir_new_space),
        .redir_slot(redir_slot),
        .f2_valid(f2_valid), .f2_insn(f2_insn), .f2_iaoq_f(f2_iaoq_f), .f2_iaoq_b(f2_iaoq_b),
        .f2_iasq_f(f2_iasq_f), .f2_iasq_b(f2_iasq_b), .f2_err(f2_err),
        .f_req(f_req), .f_addr(f_addr), .f_beat(f_beat), .f_beat_idx(f_beat_idx), .f_data(f_data),
        .f_done(f_done), .f_err(f_err));

    pa_core #(.CPU_REVISION(CPU_REVISION)) u_core (
        .clk(clk), .rst_n(rst_n),
        .f2_valid(f2_valid), .f2_insn(f2_insn), .f2_iaoq_f(f2_iaoq_f), .f2_iaoq_b(f2_iaoq_b),
        .f2_iasq_f(f2_iasq_f), .f2_iasq_b(f2_iasq_b), .f2_err(f2_err),
        .adv_f2(adv_f2), .drained(drained), .uib_inval(uib_inval),
        .redir(redir), .redir_kill_all(redir_kill_all), .redir_target(redir_target), .redir_back(redir_back),
        .redir_space(redir_space), .redir_back_space(redir_back_space), .redir_new_space(redir_new_space),
        .redir_slot(redir_slot),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_be(d_be), .d_wdata(d_wdata), .d_rclr(d_rclr),
        .d_ack(d_ack), .d_err(d_err), .d_rdata(d_rdata), .sb_empty(sb_empty), .sb_err(sb_err),
        .eir_set(eir_set), .eir_num(eir_num), .toc_req(toc_req), .hpmc_req(hpmc_req), .lpmc_req(lpmc_req),
        .powerfail(powerfail), .soft_pwr_n(soft_pwr_n), .cfg_tq(cfg_tq), .cfg_tr(cfg_tr), .cfg_td(cfg_td),
        .dbg_retire(dbg_retire), .dbg_nullified(dbg_nullified), .dbg_iaoq_f(dbg_iaoq_f), .dbg_iaoq_b(dbg_iaoq_b),
        .dbg_iasq_f(dbg_iasq_f), .dbg_insn(dbg_insn), .dbg_trap(dbg_trap), .dbg_trap_vec(dbg_trap_vec),
        .dbg_gr_we(dbg_gr_we), .dbg_gr_num0(dbg_gr_num0), .dbg_gr_num1(dbg_gr_num1),
        .dbg_gr_data0(dbg_gr_data0), .dbg_gr_data1(dbg_gr_data1), .dbg_psw(dbg_psw), .dbg_halted(dbg_halted),
        .dbg_gr(dbg_gr));

    pa_biu u_biu (
        .clk(clk), .rst_n(rst_n),
        .io_req(io_req), .io_we(io_we), .io_addr(io_addr), .io_be(io_be), .io_wdata(io_wdata),
        .io_ifetch(io_ifetch), .io_burst(io_burst), .io_rclr(io_rclr), .io_ack(io_ack), .io_last(io_last),
        .io_rdata(io_rdata), .io_err(io_err),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_be(d_be), .d_wdata(d_wdata), .d_rclr(d_rclr),
        .d_ack(d_ack), .d_err(d_err), .d_rdata(d_rdata), .sb_empty(sb_empty), .sb_err(sb_err),
        .sb_valid_o(sb_valid), .sb_addr_o(sb_addr),
        .f_req(f_req), .f_addr(f_addr), .f_beat(f_beat), .f_beat_idx(f_beat_idx), .f_data(f_data),
        .f_done(f_done), .f_err(f_err));
endmodule
