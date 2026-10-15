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
    output logic        dbg_fp_stall,       // pipelined core: D held an FP instruction for the FPU
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
        assign dbg_fp_stall = 1'b0;
    end else begin : g_pipe
        pa_cpu u_cpu (
            .clk(clk), .rst_n(rst_n), .cfg_tq(16'd1), .cfg_tr(16'd0), .cfg_td(16'd1),
            .mem_req(mem_req), .mem_we(mem_we), .mem_ifill(), .mem_addr(mem_addr), .mem_ack(mem_ack),
            .mem_wdata(mem_wdata), .mem_wvalid(mem_wvalid), .mem_wready(mem_wready), .mem_rdata(mem_rdata),
            .mem_rvalid(mem_rvalid), .mem_rbeat(mem_rbeat), .mem_rerr(mem_rerr),
            .io_req(io_req), .io_we(io_we), .io_addr(io_addr), .io_be(io_be), .io_wdata(io_wdata),
            .io_ifetch(io_ifetch), .io_burst(io_burst), .io_rclr(io_rclr), .io_ack(io_ack), .io_last(io_last),
            .io_rdata(io_rdata), .io_err(io_err),
            .eir_set(1'b0), .eir_num(5'd0), .toc_req(1'b0), .hpmc_req(1'b0), .lpmc_req(1'b0),
            .powerfail(1'b0), .soft_pwr_n(1'b1),
            .dbg_retire(dbg_retire), .dbg_nullified(dbg_nullified), .dbg_iaoq_f(dbg_iaoq_f),
            .dbg_iaoq_b(unused_b), .dbg_iasq_f(), .dbg_insn(dbg_insn), .dbg_trap(dbg_trap),
            .dbg_trap_vec(dbg_trap_vec), .dbg_gr_we(), .dbg_gr_num0(), .dbg_gr_num1(), .dbg_gr_data0(),
            .dbg_gr_data1(), .dbg_psw(dbg_psw), .dbg_halted(unused_h), .dbg_fp_stall(dbg_fp_stall), .dbg_gr(dbg_gr));
    end endgenerate

    // cacheable line port: RAM at 0 in 32-byte lines (4 doublewords, critical
    // first, wrapping), one beat per cycle after a one-cycle ack; anything
    // else answers with an error
    logic        mem_req, mem_we, mem_ack, mem_wvalid, mem_wready, mem_rvalid, mem_rerr;
    logic [31:0] mem_addr;
    logic [63:0] mem_wdata, mem_rdata;
    logic [1:0]  mem_rbeat;
    logic [2:0]  mstate;              // 0 idle, 1 acked, 2 reading, 3 writing
    logic [1:0]  mbeat;
    logic [31:0] maddr;
    wire m_is_ram = maddr[31:21] == 11'd0;
    always_ff @(posedge clk) begin
        mem_ack <= 1'b0; mem_rvalid <= 1'b0; mem_rerr <= 1'b0; mem_wready <= 1'b0;
        if (!rst_n) begin mstate <= 3'd0; mbeat <= 2'd0; end
        else case (mstate)
            3'd0: if (mem_req) begin
                mem_ack <= 1'b1; maddr <= mem_addr; mbeat <= mem_addr[4:3];
                mstate <= mem_we ? 3'd3 : 3'd2;
            end
            3'd2: begin
                mem_rvalid <= 1'b1; mem_rbeat <= mbeat; mem_rerr <= !m_is_ram;
                mem_rdata <= m_is_ram ? ram[{maddr[20:5], mbeat}] : 64'd0;
                mbeat <= mbeat + 2'd1;
                if (mbeat == maddr[4:3] + 2'd3) mstate <= 3'd0;
            end
            3'd3: begin
                mem_wready <= 1'b1;
                if (mem_wvalid && mem_wready) begin
                    if (m_is_ram) ram[{maddr[20:5], mbeat}] <= mem_wdata;
                    mbeat <= mbeat + 2'd1;
                    if (mbeat == 2'd3) begin mstate <= 3'd0; mem_wready <= 1'b0; end
                end
            end
            default: mstate <= 3'd0;
        endcase
    end

`ifdef VERILATOR
    // +dumpat=<cycle>: print the pipeline and engine states at that cycle (stalls)
    longint unsigned dump_cyc, cyc_cnt;
    logic dump_on;
    initial begin dump_on = $value$plusargs("dumpat=%d", dump_cyc); cyc_cnt = 0; end
    generate if (PIPE) begin : g_dump
        always_ff @(posedge clk) begin
            cyc_cnt <= cyc_cnt + 1;
            if (dump_on && cyc_cnt >= dump_cyc && cyc_cnt < dump_cyc + 40)
                $display("dr0=%08x wst=%0d w_valid=%0d w_insn=%08x w_trap=%0d w_cached=%0d w_hit=%0d w_dperr=%x w_fperr=%x hpmc_pend=%0d io_err=%0d dc.st=%0d dcop=%0d dc_err=%0d |  e_insn=%08x e_iaoq=%08x e_nul=%0d e_redir=%0d d_redir=%0d target=%08x d_insn=%08x d_iaoq=%08x f2_iaoq=%08x f1_iaoq=%08x nf=%08x adv=%0d adv_d=%0d d_stall=%0d",
                    g_pipe.u_cpu.u_core.dr0, g_pipe.u_cpu.u_core.wst, g_pipe.u_cpu.u_core.w_valid, g_pipe.u_cpu.u_core.w_insn,
                    g_pipe.u_cpu.u_core.w_trap, g_pipe.u_cpu.u_core.w_cached, g_pipe.u_cpu.u_core.w_hit, g_pipe.u_cpu.u_core.w_dperr,
                    g_pipe.u_cpu.u_core.w_fperr, g_pipe.u_cpu.u_core.hpmc_pend, io_err, g_pipe.u_cpu.u_dcache.st, g_pipe.u_cpu.dc_op,
                    g_pipe.u_cpu.dc_op_err,
                    g_pipe.u_cpu.u_core.e_insn, g_pipe.u_cpu.u_core.e_iaoq_f, g_pipe.u_cpu.u_core.e_nul,
                    g_pipe.u_cpu.u_core.e_redir, g_pipe.u_cpu.u_core.d_redir, g_pipe.u_cpu.redir_target,
                    g_pipe.u_cpu.u_core.d_insn, g_pipe.u_cpu.u_core.d_iaoq_f, g_pipe.u_cpu.f2_iaoq_f,
                    g_pipe.u_cpu.u_fetch.f1_iaoq_f, g_pipe.u_cpu.u_fetch.nf, g_pipe.u_cpu.u_core.adv,
                    g_pipe.u_cpu.u_core.adv_d, g_pipe.u_cpu.u_core.d_stall);
            if (dump_on && cyc_cnt == dump_cyc)
                $display("dump @%0d: w_valid=%0d wst=%0d w_insn=%08x w_iaoq=%08x w_trap=%0d w_cached=%0d w_hit=%0d | dc.st=%0d dc_op_req=%0d | ic.st=%0d ic_fill_req=%0d ic_busy=%0d | tlb.st=%0d tlb_op_req=%0d | biu.st=%0d grant=%0d sb=%0d | f1_valid=%0d f1_ready=%0d f2_valid=%0d d_valid=%0d e_valid=%0d m_valid=%0d | it_req=%0d",
                    cyc_cnt, g_pipe.u_cpu.u_core.w_valid, g_pipe.u_cpu.u_core.wst, g_pipe.u_cpu.u_core.w_insn,
                    g_pipe.u_cpu.u_core.w_iaoq_f, g_pipe.u_cpu.u_core.w_trap, g_pipe.u_cpu.u_core.w_cached, g_pipe.u_cpu.u_core.w_hit,
                    g_pipe.u_cpu.u_dcache.st, g_pipe.u_cpu.dc_op_req, g_pipe.u_cpu.u_icache.st, g_pipe.u_cpu.ic_fill_req,
                    g_pipe.u_cpu.ic_busy, g_pipe.u_cpu.u_tlb.st, g_pipe.u_cpu.tlb_op_req, g_pipe.u_cpu.u_biu.st,
                    g_pipe.u_cpu.u_biu.grant, g_pipe.u_cpu.u_biu.sb_valid, g_pipe.u_cpu.u_fetch.f1_valid,
                    g_pipe.u_cpu.u_fetch.f1_ready, g_pipe.u_cpu.u_fetch.f2_valid, g_pipe.u_cpu.u_core.d_valid,
                    g_pipe.u_cpu.u_core.e_valid, g_pipe.u_cpu.u_core.m_valid, g_pipe.u_cpu.it_req);
        end
    end endgenerate

    // +ftrace_from=<cycle> +ftrace_n=<cycles>: the fetch/decode stages per cycle (pipelined core)
    logic [63:0] ft_from, ft_n;
    logic        ft_on;
    logic [63:0] ft_cyc;
    initial begin ft_on = $value$plusargs("ftrace_from=%d", ft_from) && $value$plusargs("ftrace_n=%d", ft_n); ft_cyc = 0; end
    generate if (PIPE) begin : g_ftrace
        always_ff @(posedge clk) begin
            ft_cyc <= ft_cyc + 1;
            if (ft_on && ft_cyc >= ft_from && ft_cyc < ft_from + ft_n)
                $display("%0d nf=%08x F1 %0d %08x rdy=%0d F2 %0d %08x D %0d %08x E %0d %08x M %0d W %0d st=%0d adv=%0d advd=%0d redir=%0d(%0d) kill=%0d",
                         ft_cyc, g_pipe.u_cpu.u_fetch.nf, g_pipe.u_cpu.u_fetch.f1_valid, g_pipe.u_cpu.u_fetch.f1_iaoq_f, g_pipe.u_cpu.u_fetch.f1_ready,
                         g_pipe.u_cpu.u_fetch.f2_valid, g_pipe.u_cpu.u_fetch.f2_iaoq_f, g_pipe.u_cpu.u_core.d_valid, g_pipe.u_cpu.u_core.d_iaoq_f,
                         g_pipe.u_cpu.u_core.e_valid, g_pipe.u_cpu.u_core.e_iaoq_f, g_pipe.u_cpu.u_core.m_valid, g_pipe.u_cpu.u_core.w_valid,
                         g_pipe.u_cpu.u_core.wst, g_pipe.u_cpu.u_core.adv, g_pipe.u_cpu.u_core.adv_d, g_pipe.u_cpu.redir, g_pipe.u_cpu.redir_from_e,
                         g_pipe.u_cpu.redir_kill_all);
        end
    end endgenerate

    // +dctrace=<hex line address>: trace everything the D-cache and the line
    // port do to that 32-byte line
    logic [31:0] trace_line;
    logic        trace_on;
    initial trace_on = $value$plusargs("dctrace=%h", trace_line);
    generate if (PIPE) begin : g_trace
        always_ff @(posedge clk) if (trace_on) begin
            if (g_pipe.u_cpu.u_dcache.st != 1 && g_pipe.u_cpu.u_dcache.st != 0 && g_pipe.u_cpu.dc_op_addr[16:5] == trace_line[16:5])
                $display("%0t DC st=%0d cnt=%0d ln_req=%0d we=%0d ack=%0d wvalid=%0d wready=%0d grant=%0d beats=%0d mem_req=%0d mstate=%0d", $time,
                         g_pipe.u_cpu.u_dcache.st, g_pipe.u_cpu.u_dcache.cnt, g_pipe.u_cpu.dl_req, g_pipe.u_cpu.dl_we,
                         g_pipe.u_cpu.dl_ack, g_pipe.u_cpu.dl_wvalid, g_pipe.u_cpu.dl_wready, g_pipe.u_cpu.u_biu.grant,
                         g_pipe.u_cpu.u_biu.beats, mem_req, mstate);
            if (g_pipe.u_cpu.dc_st_we && g_pipe.u_cpu.dc_st_addr[31:5] == trace_line[31:5])
                $display("%0t ST  %08x <= %016x", $time, g_pipe.u_cpu.dc_st_addr, g_pipe.u_cpu.dc_st_data);
            if (mem_req && mem_ack == 0 && mem_addr[31:5] == trace_line[31:5] && mstate == 0)
                $display("%0t LN  %s %08x", $time, mem_we ? "WB  " : "FILL", mem_addr);
            if (mem_wvalid && mem_wready && maddr[31:5] == trace_line[31:5])
                $display("%0t WB  beat %0d %016x", $time, mbeat, mem_wdata);
            if (mem_rvalid && maddr[31:5] == trace_line[31:5])
                $display("%0t FILL beat %0d %016x", $time, mem_rbeat, mem_rdata);
            if (g_pipe.u_cpu.dc_op_req && !g_pipe.u_cpu.dc_op_done && g_pipe.u_cpu.u_dcache.st == 3 &&
                g_pipe.u_cpu.dc_op_addr[16:5] == trace_line[16:5])
                $display("%0t OP  %0d addr %08x tag rpn=%05x dirty=%0d valid=%0d wb=%0d", $time, g_pipe.u_cpu.dc_op,
                         g_pipe.u_cpu.dc_op_addr, g_pipe.u_cpu.u_dcache.tq_rpn, g_pipe.u_cpu.u_dcache.tq_dirty,
                         g_pipe.u_cpu.u_dcache.tq_valid, g_pipe.u_cpu.u_dcache.wb_needed);
        end
    end endgenerate
`endif

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
