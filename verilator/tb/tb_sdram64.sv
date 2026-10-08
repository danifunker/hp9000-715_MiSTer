// tb_sdram64 -- unit bench for rtl/mister/sdram64.sv against a behavioural
// SDR SDRAM (two ranks, as on the 128 MB MiSTer module). Random line and
// doubleword reads and writes with random byte enables, through the RAM
// port's protocol (rtl/mioc.sv), checked against a reference memory; the
// chip model checks the command protocol and timing at 64 MHz.
//   make -C verilator tb_sdram64
`timescale 1ns/1ps
module tb_sdram64;
    logic clk = 0;
    always #7.8125 clk = ~clk;          // 64 MHz

    logic        rst = 1;
    logic        ready;
    logic        ram_req = 0, ram_we = 0, ram_line = 0;
    logic [26:0] ram_addr = 0;
    logic [7:0]  ram_be = 0;
    logic [63:0] ram_wdata = 0;
    logic        ram_ack, ram_wready, ram_rvalid;
    logic [1:0]  ram_rbeat;
    logic [63:0] ram_rdata;
    wire  [15:0] DQ;
    logic [12:0] A;
    logic [1:0]  BA;
    logic        DQML, DQMH, nCS, nRAS, nCAS, nWE, CKE;

    sdram64 #(.CLK_HZ(64_000_000)) dut (
        .clk(clk), .clk_sdram(clk), .rst(rst), .rd_mode(2'd3), .ready(ready),
        .ram_req(ram_req), .ram_we(ram_we), .ram_line(ram_line), .ram_addr(ram_addr), .ram_be(ram_be),
        .ram_wdata(ram_wdata), .ram_ack(ram_ack), .ram_wready(ram_wready), .ram_rvalid(ram_rvalid),
        .ram_rbeat(ram_rbeat), .ram_rdata(ram_rdata),
        .SDRAM_DQ(DQ), .SDRAM_A(A), .SDRAM_BA(BA), .SDRAM_DQML(DQML), .SDRAM_DQMH(DQMH),
        .SDRAM_nCS(nCS), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS), .SDRAM_nWE(nWE), .SDRAM_CKE(CKE));

    sdram_chip #(.INV_CS(0)) rank0 (.clk(clk), .nCS(nCS), .nRAS(nRAS), .nCAS(nCAS), .nWE(nWE),
        .ba(BA), .a(A), .dqmh(DQMH), .dqml(DQML), .dq(DQ), .ctl_drives(dut.dq_oe));
    sdram_chip #(.INV_CS(1)) rank1 (.clk(clk), .nCS(nCS), .nRAS(nRAS), .nCAS(nCAS), .nWE(nWE),
        .ba(BA), .a(A), .dqmh(DQMH), .dqml(DQML), .dq(DQ), .ctl_drives(dut.dq_oe));

    // reference memory over the addresses the test uses
    logic [63:0] ref_mem [int];
    int errors = 0, checks = 0;

    function automatic logic [63:0] ref_rd(input logic [26:3] dw);
        return ref_mem.exists(int'(dw)) ? ref_mem[int'(dw)] : 64'hFFFF_FFFF_FFFF_FFFF;
    endfunction

    // the test's addresses: 2 ranks x 4 banks x 3 rows x 4 lines, plus column bit 9
    function automatic logic [26:0] rnd_line();
        logic [26:0] a;
        a = 27'd0;
        a[26] = $urandom_range(0, 1);
        a[24:23] = $urandom_range(0, 3);
        a[22:10] = 13'($urandom_range(0, 2) * 4099);
        a[25] = $urandom_range(0, 1);
        a[9:5] = 5'($urandom_range(0, 3) * 9);
        return a;
    endfunction

    // The bench drives and samples on the falling edge: the DUT's registered
    // outputs are stable there, and what the bench sets is what the DUT sees
    // at the next rising edge. ram_wready high at a falling edge means the
    // DUT takes ram_wdata at the rising edge that follows.
    task automatic do_write(input logic [26:0] a, input logic line, input logic [7:0] be, input logic [63:0] d [4]);
        int n;
        bit taken;
        @(negedge clk);
        ram_req = 1; ram_we = 1; ram_line = line; ram_addr = a; ram_be = line ? 8'hFF : be;
        ram_wdata = d[0];
        n = 0; taken = 0;
        while (n < (line ? 4 : 1) || taken) begin
            @(negedge clk);
            if (taken && n < 4) ram_wdata = d[n];
            taken = 0;
            if (ram_ack) ram_req = 0;
            if (ram_wready) begin n++; taken = 1; end
            if (n == (line ? 4 : 1) && taken) begin taken = 0; break; end
        end
        ram_req = 0;
        for (int i = 0; i < (line ? 4 : 1); i++) begin
            logic [26:3] dw;
            logic [63:0] m;
            dw = line ? {a[26:5], 2'(i)} : a[26:3];
            m = ref_rd(dw);
            for (int b = 0; b < 8; b++) if (line || be[b]) m[8*b +: 8] = d[i][8*b +: 8];
            ref_mem[int'(dw)] = m;
        end
    endtask

    task automatic do_read(input logic [26:0] a, input logic line);
        int n;
        logic [3:0] seen;
        @(negedge clk);
        ram_req = 1; ram_we = 0; ram_line = line; ram_addr = a;
        n = 0; seen = 0;
        while (n < (line ? 4 : 1)) begin
            @(negedge clk);
            if (ram_ack) ram_req = 0;
            if (ram_rvalid) begin
                logic [26:3] dw;
                logic [63:0] e;
                if (n == 0 && ram_rbeat != a[4:3]) begin
                    $display("FAIL: first beat %0d, wanted the critical doubleword %0d (addr %07x)", ram_rbeat, a[4:3], a);
                    errors++;
                end
                if (seen[ram_rbeat]) begin $display("FAIL: beat %0d twice", ram_rbeat); errors++; end
                seen[ram_rbeat] = 1'b1;
                dw = {a[26:5], ram_rbeat};
                e = ref_rd(dw);
                checks++;
                if ($test$plusargs("directed")) $display("  read %07x beat %0d = %016x", a, ram_rbeat, ram_rdata);
                if (ram_rdata !== e) begin
                    $display("FAIL: %s read %07x beat %0d: %016x, wanted %016x", line ? "line" : "dw",
                             a, ram_rbeat, ram_rdata, e);
                    errors++;
                end
                n++;
            end
        end
        ram_req = 0;
    endtask

    longint t_start, t_line = 0, n_line = 0;
    initial begin
        logic [63:0] d [4];
        repeat (10) @(negedge clk);
        rst = 0;
        wait (ready);
        $display("tb_sdram64: initialised after %0t", $time);
        if ($test$plusargs("directed")) begin
            for (int i = 0; i < 4; i++) d[i] = {4{16'h1000 * (i + 1) + 16'h0101}} + {16'h0, 16'h1, 16'h2, 16'h3};
            do_write(27'h100, 1'b1, 8'hFF, d);
            for (int c = 0; c < 4; c++) do_read(27'h100 | (c << 3), 1'b1);
            do_read(27'h108, 1'b0);
            $display("directed: %0d errors", errors);
        end
        for (int it = 0; it < 4000; it++) begin
            logic [26:0] a;
            int op;
            a = rnd_line();
            a[4:3] = $urandom_range(0, 3);
            for (int i = 0; i < 4; i++) d[i] = {$urandom, $urandom};
            op = $urandom_range(0, 3);
            case (op)
                0: do_write(a, 1'b1, 8'hFF, d);
                1: do_write(a, 1'b0, 8'($urandom_range(1, 255)), d);
                2: begin t_start = $time; do_read(a, 1'b1); t_line += $time - t_start; n_line++; end
                default: do_read(a, 1'b0);
            endcase
        end
        repeat (20) @(posedge clk);
        $display("tb_sdram64: %0d beats checked, %0d errors, chip protocol errors %0d + %0d, refreshes %0d / %0d",
                 checks, errors, rank0.errors, rank1.errors, rank0.n_refresh, rank1.n_refresh);
        $display("tb_sdram64: line read %0.1f cycles from request to the last beat",
                 real'(t_line) / n_line / 15.625);
        if (errors == 0 && rank0.errors == 0 && rank1.errors == 0 && rank0.n_refresh > 0) $display("tb_sdram64: PASS");
        else $display("tb_sdram64: FAIL");
        $finish;
    end
endmodule

// A behavioural SDR SDRAM rank: 4 banks, 13-bit rows, 10-bit columns, CAS
// latency and burst length from the mode register, sequential bursts that
// wrap in their aligned block, write bursts with DQM, auto-precharge,
// refresh, and the 64 MHz timing the controller must keep (tRCD 2, tRP 2,
// tRAS 3, tRC 4, tRFC 5 cycles). After the Quadra core's sdram_model
// (../MacQuadra800_MiSTer/verilator/tb_sdram.sv), with write bursts added.
// INV_CS = 1 models the module's second rank, selected by nCS high.
module sdram_chip #(parameter bit INV_CS = 0) (
    input logic        clk,
    input logic        nCS, nRAS, nCAS, nWE,
    input logic [1:0]  ba,
    input logic [12:0] a,
    input logic        dqmh, dqml,
    inout wire  [15:0] dq,
    input logic        ctl_drives      // the controller drives DQ this cycle
);
    localparam int T_RCD = 2, T_RP = 2, T_RAS = 3, T_RC = 4, T_RFC = 5;
    logic [15:0] mem [int];
    int errors = 0, n_refresh = 0;
    bit mode_set = 0;
    int cl = 2, bl = 1;
    bit wburst = 0;
    bit row_open [4];
    logic [12:0] row [4];
    int now = 0, t_act [4], t_pre [4], t_ref = -100;
    // read pipeline
    bit        pv [16];
    logic [15:0] pd [16];
    bit        drive = 0;
    logic [15:0] dval = 0;
    assign dq = drive ? dval : 16'hZZZZ;
    // write burst in progress
    int wb_left = 0, wb_bank, wb_col;
    bit wb_ap = 0;

    function automatic int key(input logic [1:0] b, input logic [12:0] r, input logic [9:0] c);
        return {7'd0, b, r, c};
    endfunction
    task automatic err(input string s);
        $display("CHIP%0d %s (cycle %0d)", INV_CS, s, now); errors++;
    endtask

    initial for (int i = 0; i < 4; i++) begin row_open[i] = 0; t_act[i] = -100; t_pre[i] = -100; end

    wire sel = INV_CS ? nCS : !nCS;
    wire [2:0] cmd = sel ? {nRAS, nCAS, nWE} : 3'b111;

    always @(posedge clk) begin
        now++;
        if (drive && ctl_drives) err("bus contention: chip and controller both drive DQ");
        drive <= pv[0]; dval <= pd[0];
        for (int j = 0; j < 15; j++) begin pv[j] = pv[j+1]; pd[j] = pd[j+1]; end
        pv[15] = 0;
        // write burst words after the first
        if (wb_left > 0 && cmd == 3'b111) begin
            int k;
            k = key(2'(wb_bank), row[wb_bank], 10'(wb_col));
            if (!dqmh || !dqml) begin
                if (!mem.exists(k)) mem[k] = 16'hFFFF;
                if (!dqmh) mem[k][15:8] = dq[15:8];
                if (!dqml) mem[k][7:0] = dq[7:0];
            end
            wb_col = (wb_col & ~(bl - 1)) | ((wb_col + 1) & (bl - 1));
            wb_left--;
            if (wb_left == 0 && wb_ap) begin row_open[wb_bank] = 0; t_pre[wb_bank] = now + 2; end
        end else if (wb_left > 0) wb_left = 0;         // interrupted
        case (cmd)
            3'b000: begin mode_set = 1; cl = a[6:4]; bl = 1 << a[2:0]; wburst = !a[9]; end
            3'b001: begin
                for (int i = 0; i < 4; i++) if (row_open[i]) err("REFRESH with a row open");
                for (int i = 0; i < 4; i++) if (now - t_pre[i] < T_RP) err("tRP before REFRESH");
                t_ref = now; n_refresh++;
            end
            3'b010: for (int i = 0; i < 4; i++) if (a[10] || i == ba) begin
                if (row_open[i] && now - t_act[i] < T_RAS) err("tRAS");
                row_open[i] = 0; t_pre[i] = now;
            end
            3'b011: begin
                if (!mode_set) err("ACTIVE before LOAD MODE");
                if (row_open[ba]) err("ACTIVE with the row open");
                if (now - t_pre[ba] < T_RP) err($sformatf("tRP bank %0d: %0d", ba, now - t_pre[ba]));
                if (now - t_act[ba] < T_RC) err("tRC");
                if (now - t_ref < T_RFC) err("tRFC");
                row_open[ba] = 1; row[ba] = a; t_act[ba] = now;
            end
            3'b101, 3'b100: begin
                int col, k;
                col = a[9:0];
                if (!row_open[ba]) err("READ/WRITE with no row open");
                else if (now - t_act[ba] < T_RCD) err("tRCD");
                if (cmd == 3'b101) begin
                    for (int j = 0; j < bl; j++) begin
                        int c;
                        c = (col & ~(bl - 1)) | ((col + j) & (bl - 1));
                        k = key(ba, row[ba], 10'(c));
                        pv[cl - 1 + j] = 1;
                        pd[cl - 1 + j] = mem.exists(k) ? mem[k] : 16'hFFFF;
                    end
                    if (a[10]) begin row_open[ba] = 0; t_pre[ba] = now + bl; end
                end else begin
                    k = key(ba, row[ba], 10'(col));
                    if (!dqmh || !dqml) begin
                        if (!mem.exists(k)) mem[k] = 16'hFFFF;
                        if (!dqmh) mem[k][15:8] = dq[15:8];
                        if (!dqml) mem[k][7:0] = dq[7:0];
                    end
                    if (wburst && bl > 1) begin
                        wb_left = bl - 1; wb_bank = ba; wb_ap = a[10];
                        wb_col = (col & ~(bl - 1)) | ((col + 1) & (bl - 1));
                    end else if (a[10]) begin row_open[ba] = 0; t_pre[ba] = now + 2; end
                end
            end
            default: ;
        endcase
    end
endmodule
