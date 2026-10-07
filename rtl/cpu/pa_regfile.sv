// General registers for the pipelined core (docs/design/cpu.md 6.4).
//
// GR1, 8, 9, 16, 17, 24, 25 and their seven shadow registers are flip-flops,
// so an interruption's shadow capture, RFIR, SHDW_GR and GR_SHDW are
// single-cycle parallel copies (ACD p.2-8, ERS s.2.2.2). The other GRs live in
// MLAB LUT-RAM with asynchronous reads, two write ports x two read ports:
// one bank per write port, each bank read twice, and a live-value table
// says which bank holds the newest copy of a register.
//
// Reads are asynchronous (D stage); writes land at the clock edge (W stage).
// A W-stage write is not visible to a same-cycle read: the core bypasses it.
// Port 0 is the instruction target, port 1 the base-register modification;
// when both name the same register port 0 wins (ACD p.5-40: the loaded value
// wins over the base update).
module pa_regfile (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [4:0]  ra0, ra1,
    output logic [31:0] rd0, rd1,
    input  logic        we0, we1,
    input  logic [4:0]  wa0, wa1,
    input  logic [31:0] wd0, wd1,
    // shadow operations (W stage, exclusive with ordinary writes of GR1/8/..)
    input  logic        shr_capture,    // SHR <- GR (interruption, GR_SHDW)
    input  logic        shr_restore,    // GR <- SHR (RFIR, SHDW_GR)
    output logic [31:0] dbg_gr [32]     // simulation mirror of every GR
);
    function automatic logic is_ff(input logic [4:0] r);
        case (r)
            5'd1, 5'd8, 5'd9, 5'd16, 5'd17, 5'd24, 5'd25: is_ff = 1'b1;
            default: is_ff = 1'b0;
        endcase
    endfunction
    function automatic logic [2:0] ff_idx(input logic [4:0] r);
        case (r)
            5'd1: ff_idx = 3'd0; 5'd8: ff_idx = 3'd1; 5'd9: ff_idx = 3'd2; 5'd16: ff_idx = 3'd3;
            5'd17: ff_idx = 3'd4; 5'd24: ff_idx = 3'd5; default: ff_idx = 3'd6;
        endcase
    endfunction

    // ------------------------------------------------------------ flip-flop GRs
    logic [31:0] grf [7];
    logic [31:0] shr [7];
    wire we1_eff = we1 && !(we0 && wa0 == wa1);
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int i = 0; i < 7; i++) begin grf[i] <= 32'd0; shr[i] <= 32'd0; end
        end else begin
            if (shr_restore) grf <= shr;
            else begin
                if (we0 && is_ff(wa0)) grf[ff_idx(wa0)] <= wd0;
                if (we1_eff && is_ff(wa1)) grf[ff_idx(wa1)] <= wd1;
            end
            if (shr_capture) shr <= grf;
        end
    end

    // ------------------------------------------------------------ MLAB banks
    (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] bank0a [32];
    (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] bank0b [32];
    (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] bank1a [32];
    (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] bank1b [32];
    logic [31:0] lvt;                       // 1 = bank1 holds the newest value
    always_ff @(posedge clk) begin
        if (we0)     begin bank0a[wa0] <= wd0; bank0b[wa0] <= wd0; end
        if (we1_eff) begin bank1a[wa1] <= wd1; bank1b[wa1] <= wd1; end
    end
    always_ff @(posedge clk) begin
        if (!rst_n) lvt <= 32'd0;
        else begin
            if (we0)     lvt[wa0] <= 1'b0;
            if (we1_eff) lvt[wa1] <= 1'b1;
        end
    end
    // read: flop GRs win over the banks; GR0 reads 0
    wire [31:0] m0 = lvt[ra0] ? bank1a[ra0] : bank0a[ra0];
    wire [31:0] m1 = lvt[ra1] ? bank1b[ra1] : bank0b[ra1];
    assign rd0 = (ra0 == 5'd0) ? 32'd0 : is_ff(ra0) ? grf[ff_idx(ra0)] : m0;
    assign rd1 = (ra1 == 5'd0) ? 32'd0 : is_ff(ra1) ? grf[ff_idx(ra1)] : m1;

    // ------------------------------------------------------------ simulation mirror
`ifdef VERILATOR
    always_ff @(posedge clk) begin
        if (!rst_n) for (int i = 0; i < 32; i++) dbg_gr[i] <= 32'd0;
        else begin
            if (shr_restore) begin
                dbg_gr[1] <= shr[0]; dbg_gr[8] <= shr[1]; dbg_gr[9] <= shr[2]; dbg_gr[16] <= shr[3];
                dbg_gr[17] <= shr[4]; dbg_gr[24] <= shr[5]; dbg_gr[25] <= shr[6];
            end else begin
                if (we0 && wa0 != 0) dbg_gr[wa0] <= wd0;
                if (we1_eff && wa1 != 0) dbg_gr[wa1] <= wd1;
            end
        end
    end
`else
    always_comb for (int i = 0; i < 32; i++) dbg_gr[i] = 32'd0;
`endif
endmodule
