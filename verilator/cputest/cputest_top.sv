// CPU test harness: a CPU core + a minimal system for the pacputest ROMs
// (tests/cpu): ROM at 0xF0000000 (+rom=<hex>, 64-bit words), 2 MB RAM at 0,
// the LASI 16550 at 0xF0105800 (THR writes go to the serial tap, LSR reads
// 0x60), and a bus error (io_err) for anything else -- the core turns that
// into an HPMC, as the real machine does. PIPE = 0: the sequential core
// pa_core_seq; PIPE = 1: the pipelined pa_cpu. Bursts (io_burst) return four
// doublewords, one per cycle, io_last on the fourth.
module cputest_top #(
    parameter bit PIPE = 1'b0
) (
    input  logic        clk,
    input  logic        rst_n,
    output logic        uart_tx_strobe,
    output logic [7:0]  uart_tx_byte,
    output logic        dbg_retire,
    output logic        dbg_nullified,
    output logic [31:0] dbg_iaoq_f,
    output logic [31:0] dbg_insn,
    output logic        dbg_trap,
    output logic [5:0]  dbg_trap_vec,
    output logic [31:0] dbg_psw,
    output logic [31:0] dbg_gr [32]
);
    localparam int ROM_WORDS = 32768;        // 256 KB
    localparam int RAM_WORDS = 262144;       // 2 MB
    logic [63:0] rom [ROM_WORDS];
    logic [63:0] ram [RAM_WORDS];
    initial begin
        string f;
        for (int i = 0; i < ROM_WORDS; i++) rom[i] = 64'd0;
        if ($value$plusargs("rom=%s", f)) $readmemh(f, rom);
        else $display("cputest_top: no +rom=<hexfile>");
    end

    logic        io_req, io_we, io_ifetch, io_rclr, io_burst, io_ack, io_last, io_err;
    logic [31:0] io_addr;
    logic [7:0]  io_be;
    logic [63:0] io_wdata, io_rdata;
    logic [31:0] unused_b;
    logic        unused_h;

    generate if (!PIPE) begin : g_seq
        pa_core_seq u_cpu (
            .clk(clk), .rst_n(rst_n),
            .io_req(io_req), .io_we(io_we), .io_addr(io_addr), .io_be(io_be), .io_wdata(io_wdata),
            .io_ifetch(io_ifetch), .io_rclr(io_rclr), .io_ack(io_ack), .io_rdata(io_rdata),
            .io_err(io_err),
            .eir_set(1'b0), .eir_num(5'd0), .toc_req(1'b0),
            .dbg_retire(dbg_retire), .dbg_nullified(dbg_nullified), .dbg_iaoq_f(dbg_iaoq_f),
            .dbg_iaoq_b(unused_b), .dbg_insn(dbg_insn), .dbg_trap(dbg_trap),
            .dbg_trap_vec(dbg_trap_vec), .dbg_psw(dbg_psw), .dbg_halted(unused_h), .dbg_gr(dbg_gr));
        assign io_burst = 1'b0;
    end else begin : g_pipe
        pa_cpu u_cpu (
            .clk(clk), .rst_n(rst_n), .cfg_tq(16'd1), .cfg_tr(16'd0), .cfg_td(16'd1),
            .mem_req(), .mem_we(), .mem_ifill(), .mem_addr(), .mem_ack(1'b0), .mem_wdata(), .mem_wvalid(),
            .mem_wready(1'b0), .mem_rdata(64'd0), .mem_rvalid(1'b0), .mem_rbeat(2'd0), .mem_rerr(1'b0),
            .io_req(io_req), .io_we(io_we), .io_addr(io_addr), .io_be(io_be), .io_wdata(io_wdata),
            .io_ifetch(io_ifetch), .io_burst(io_burst), .io_rclr(io_rclr), .io_ack(io_ack), .io_last(io_last),
            .io_rdata(io_rdata), .io_err(io_err),
            .eir_set(1'b0), .eir_num(5'd0), .toc_req(1'b0), .hpmc_req(1'b0), .lpmc_req(1'b0),
            .powerfail(1'b0), .soft_pwr_n(1'b1),
            .dbg_retire(dbg_retire), .dbg_nullified(dbg_nullified), .dbg_iaoq_f(dbg_iaoq_f),
            .dbg_iaoq_b(unused_b), .dbg_iasq_f(), .dbg_insn(dbg_insn), .dbg_trap(dbg_trap),
            .dbg_trap_vec(dbg_trap_vec), .dbg_gr_we(), .dbg_gr_num0(), .dbg_gr_num1(), .dbg_gr_data0(),
            .dbg_gr_data1(), .dbg_psw(dbg_psw), .dbg_halted(unused_h), .dbg_gr(dbg_gr));
    end endgenerate

    // one-cycle response; a burst answers four consecutive doublewords
    logic [1:0]  beat;
    wire [31:0] cur_addr = io_burst ? {io_addr[31:5], beat, 3'd0} : io_addr;
    wire is_rom  = cur_addr[31:18] == 14'h3C00;                 // F0000000-F003FFFF
    wire is_ram  = cur_addr[31:21] == 11'd0;                    // 0-1FFFFF
    wire is_uart = cur_addr[31:3] == 29'h1E020B00;              // F0105800-F0105807
    logic [63:0] merged;
    logic        dlab = 1'b0;
    always_comb
        for (int b = 0; b < 8; b++)
            merged[63-8*b -: 8] = io_be[7-b] ? io_wdata[63-8*b -: 8]
                                              : ram[io_addr[20:3]][63-8*b -: 8];

    always_ff @(posedge clk) begin
        io_ack <= 1'b0;
        io_err <= 1'b0;
        io_last <= 1'b0;
        uart_tx_strobe <= 1'b0;
        if (!rst_n) beat <= 2'd0;
        if (io_req && (!io_ack || (io_burst && !io_last))) begin
            io_ack <= 1'b1;
            if (io_burst) begin
                beat <= beat + 2'd1;
                if (beat == 2'd3) io_last <= 1'b1;
            end
            if (is_rom) begin
                io_rdata <= rom[cur_addr[17:3]];
                if (io_we) io_err <= 1'b1;
            end else if (is_ram) begin
                io_rdata <= ram[cur_addr[20:3]];
                if (io_we) ram[io_addr[20:3]] <= merged;
                else if (io_rclr) begin                       // LDCW: clear the word read
                    if (io_addr[2]) ram[io_addr[20:3]][31:0] <= 32'd0;
                    else            ram[io_addr[20:3]][63:32] <= 32'd0;
                end
            end else if (is_uart) begin
                io_rdata <= {40'd0, 8'h60, 16'd0};             // LSR (offset 5) = THRE|TEMT
                if (io_we && io_be[4]) dlab <= io_wdata[39];  // LCR (offset 3) bit 7
                if (io_we && io_be[7] && !dlab) begin         // THR, offset 0 (DLL when DLAB)
                    uart_tx_strobe <= 1'b1;
                    uart_tx_byte <= io_wdata[63:56];
                end
            end else begin
                io_rdata <= 64'd0;
                io_err <= 1'b1;
            end
        end
    end
endmodule
