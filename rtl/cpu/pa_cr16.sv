// Interval timer CR16 (docs/design/cpu.md 5.2): counts at exactly the board
// clock (64/80/100 MHz on a 715) from a fractional tick generator driven by
// the core clock, f_board / f_core = TQ + TR / TD. A compare match sets
// EIRR bit 0 (PA numbering) and is detected over the whole step so a 2-tick
// step never skips it. MTCTL CR16 writes the compare, DR1 the counter;
// neither checks for a match (BOOT s.4.2 0x4108C).
module pa_cr16 (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [15:0] tq, tr, td,
    input  logic        wr_counter,     // DR1
    input  logic        wr_compare,     // MTCTL CR16
    input  logic [31:0] wdata,
    output logic [31:0] counter,
    output logic        match           // one-cycle pulse
);
    logic [31:0] compare;
    logic [16:0] acc;
    logic [16:0] s;
    logic        c;
    logic [16:0] inc;
    logic [31:0] to_cmp;
    always_comb begin
        s   = acc + {1'b0, tr};
        c   = s >= {1'b0, td};
        inc = {1'b0, tq} + {16'd0, c};
        to_cmp = compare - counter - 32'd1;         // compare in (old, old + inc]
    end
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            counter <= 32'd0; compare <= 32'd0; acc <= 17'd0; match <= 1'b0;
        end else begin
            acc <= c ? s - {1'b0, td} : s;
            match <= 1'b0;
            if (wr_counter) counter <= wdata;
            else begin
                counter <= counter + {15'd0, inc};
                if (inc != 0 && to_cmp < {15'd0, inc}) match <= 1'b1;
            end
            if (wr_compare) compare <= wdata;
        end
    end
endmodule
