// CPU test harness: the sequential core + a minimal system for the pacputest
// ROMs (tests/cpu): ROM at 0xF0000000 (+rom=<hex>, 64-bit words), 2 MB RAM
// at 0, the LASI 16550 at 0xF0105800 (THR writes go to the serial tap, LSR
// reads 0x60), and a bus error (io_err) for anything else -- the core turns
// that into an HPMC, as the real machine does.
module cputest_top (
    input  logic        clk,
    input  logic        rst_n,
    output logic        uart_tx_strobe,
    output logic [7:0]  uart_tx_byte,
    output logic        dbg_retire,
    output logic        dbg_nullified,
    output logic [31:0] dbg_iaoq_f,
    output logic [31:0] dbg_insn,
    output logic        dbg_trap,
    output logic [5:0]  dbg_trap_vec
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

    logic        io_req, io_we, io_ifetch, io_rclr, io_ack, io_err;
    logic [31:0] io_addr;
    logic [7:0]  io_be;
    logic [63:0] io_wdata, io_rdata;
    logic [31:0] unused_b;
    logic [31:0] unused_psw;
    logic        unused_h;

    pa_core_seq u_cpu (
        .clk(clk), .rst_n(rst_n),
        .io_req(io_req), .io_we(io_we), .io_addr(io_addr), .io_be(io_be), .io_wdata(io_wdata),
        .io_ifetch(io_ifetch), .io_rclr(io_rclr), .io_ack(io_ack), .io_rdata(io_rdata),
        .io_err(io_err),
        .eir_set(1'b0), .eir_num(5'd0), .toc_req(1'b0),
        .dbg_retire(dbg_retire), .dbg_nullified(dbg_nullified), .dbg_iaoq_f(dbg_iaoq_f),
        .dbg_iaoq_b(unused_b), .dbg_insn(dbg_insn), .dbg_trap(dbg_trap),
        .dbg_trap_vec(dbg_trap_vec), .dbg_psw(unused_psw), .dbg_halted(unused_h));

    // one-cycle response
    wire is_rom  = io_addr[31:18] == 14'h3C00;                  // F0000000-F003FFFF
    wire is_ram  = io_addr[31:21] == 11'd0;                     // 0-1FFFFF
    wire is_uart = io_addr[31:3] == 29'h1E020B00;               // F0105800-F0105807
    logic [63:0] merged;
    logic        dlab = 1'b0;
    always_comb
        for (int b = 0; b < 8; b++)
            merged[63-8*b -: 8] = io_be[7-b] ? io_wdata[63-8*b -: 8]
                                              : ram[io_addr[20:3]][63-8*b -: 8];

    always_ff @(posedge clk) begin
        io_ack <= 1'b0;
        io_err <= 1'b0;
        uart_tx_strobe <= 1'b0;
        if (io_req && !io_ack) begin
            io_ack <= 1'b1;
            if (is_rom) begin
                io_rdata <= rom[io_addr[17:3]];
                if (io_we) io_err <= 1'b1;
            end else if (is_ram) begin
                io_rdata <= ram[io_addr[20:3]];
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
