// Lockstep co-simulation: the sequential reference core and the pipelined
// core, each in its own copy of the test system (ROM, RAM, UART), driven by
// one clock. tb_cosim.cpp compares their retirement streams.
module cosim_top (
    input  logic        clk_a, clk_b,   // one clock each: the driver pauses the core that is ahead
    input  logic        rst_n,
    output logic        a_uart_strobe, b_uart_strobe,
    output logic [7:0]  a_uart_byte, b_uart_byte,
    output logic        a_retire, b_retire, a_nul, b_nul, a_trap, b_trap,
    output logic [31:0] a_iaoq_f, b_iaoq_f, a_insn, b_insn, a_psw, b_psw,
    output logic [5:0]  a_vec, b_vec,
    output logic [31:0] a_gr [32],
    output logic [31:0] b_gr [32]
);
    cputest_top #(.PIPE(1'b0)) u_a (
        .clk(clk_a), .rst_n(rst_n), .uart_tx_strobe(a_uart_strobe), .uart_tx_byte(a_uart_byte),
        .dbg_retire(a_retire), .dbg_nullified(a_nul), .dbg_iaoq_f(a_iaoq_f), .dbg_insn(a_insn),
        .dbg_trap(a_trap), .dbg_trap_vec(a_vec), .dbg_psw(a_psw), .dbg_gr(a_gr));
    cputest_top #(.PIPE(1'b1)) u_b (
        .clk(clk_b), .rst_n(rst_n), .uart_tx_strobe(b_uart_strobe), .uart_tx_byte(b_uart_byte),
        .dbg_retire(b_retire), .dbg_nullified(b_nul), .dbg_iaoq_f(b_iaoq_f), .dbg_insn(b_insn),
        .dbg_trap(b_trap), .dbg_trap_vec(b_vec), .dbg_psw(b_psw), .dbg_gr(b_gr));
endmodule
