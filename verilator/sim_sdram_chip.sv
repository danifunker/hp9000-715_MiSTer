// The romsim's SDRAM (verilator/sim.v with +define+SDRAM_MODEL): the unit
// bench's chip model (verilator/tb/tb_sdram64.sv) with a fixed array instead
// of an associative one, so the whole machine runs on rtl/mister/sdram64.sv
// as on the board -- its latency, refresh stalls and burst order -- with
// SDRAM_CLK in phase (sdram64 rd_mode 3). Board-only I/O timing is not
// modelled (STUBS S-019).
// A behavioural SDR SDRAM rank: 4 banks, 13-bit rows, 10-bit columns, CAS
// latency and burst length from the mode register, sequential bursts that
// wrap in their aligned block, write bursts with DQM, auto-precharge,
// refresh, and the 64 MHz timing the controller must keep (tRCD 2, tRP 2,
// tRAS 3, tRC 4, tRFC 5 cycles). After the Quadra core's sdram_model
// (../MacQuadra800_MiSTer/verilator/tb_sdram.sv), with write bursts added.
// INV_CS = 1 models the module's second rank, selected by nCS high.
module sim_sdram_chip #(parameter bit INV_CS = 0, parameter int MEM_LG = 25) (
    input logic        clk,
    input logic        nCS, nRAS, nCAS, nWE,
    input logic [1:0]  ba,
    input logic [12:0] a,
    input logic        dqmh, dqml,
    inout wire  [15:0] dq,
    input logic        ctl_drives      // the controller drives DQ this cycle
);
    localparam int T_RCD = 2, T_RP = 2, T_RAS = 3, T_RC = 4, T_RFC = 5;
    logic [15:0] mem [1 << MEM_LG];      // {bank, row, column}: 64 MB at MEM_LG 25
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
                        pd[cl - 1 + j] = mem[k];
                    end
                    if (a[10]) begin row_open[ba] = 0; t_pre[ba] = now + bl; end
                end else begin
                    k = key(ba, row[ba], 10'(col));
                    if (!dqmh || !dqml) begin
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
