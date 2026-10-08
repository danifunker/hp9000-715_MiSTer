// Board-side event recorder: the machine's debug events (rtl/hp715.sv
// dbg_ev_*) as 32-byte records in a ring in DDR3, which the MiSTer's Linux
// reads through /dev/mem (tools/mister/trace_dump.py) -- the board's view of
// what the simulator's --scsitrace / --miotrace print.
//
// Record (four little-endian 64-bit words at TRACE_BASE + 32 * (seq % N)):
//   word 0: {cycle[31:0], seq[31:0]}
//   word 1: {type[7:0], aux[7:0], 16'd0, addr[31:0]}
//   word 2: data[63:0]
//   word 3: 0
// seq counts every event, so the reader finds the newest record and any it
// lost (dropped events still count; `drops` counts them too).
module trace_ddr3 #(
    parameter int LG_N = 16                  // 64K records = 2 MB
) (
    input  logic         clk,
    input  logic         rst,
    input  logic         ev_valid,
    input  logic [111:0] ev,                 // {type, aux, addr, data}
    // to rtl/mister/ddr3_port.sv: one 4-beat write per record
    output logic         tr_req,
    output logic [LG_N-1:0] tr_idx,
    output logic [255:0] tr_data,
    input  logic         tr_ack,
    output logic [31:0]  drops
);
    // 16-entry FIFO of {seq, cycle, event}
    localparam int W = 32 + 32 + 112;
    logic [W-1:0] fifo [16];
    logic [3:0]   wp, rp;
    logic [4:0]   n;
    logic [31:0]  seq, cyc;

    always_ff @(posedge clk) begin
        cyc <= cyc + 32'd1;
        if (rst) begin
            wp <= 0; rp <= 0; n <= 0; seq <= 0; drops <= 0; tr_req <= 1'b0;
        end else begin
            logic push, pop;
            push = ev_valid && n != 5'd16;
            pop = 1'b0;
            if (ev_valid) seq <= seq + 32'd1;
            if (ev_valid && n == 5'd16) drops <= drops + 32'd1;
            if (push) begin fifo[wp] <= {seq, cyc, ev}; wp <= wp + 4'd1; end
            if (tr_req) begin
                if (tr_ack) tr_req <= 1'b0;
            end else if (n != 5'd0) begin
                logic [W-1:0] e;
                e = fifo[rp];
                tr_req <= 1'b1;
                tr_idx <= e[W-32 +: LG_N];               // the low bits of seq
                tr_data <= {64'd0, e[63:0], e[111:104], e[103:96], 16'd0, e[95:64], e[W-33 -: 32], e[W-1 -: 32]};
                rp <= rp + 4'd1;
                pop = 1'b1;
            end
            n <= n + (push ? 5'd1 : 5'd0) - (pop ? 5'd1 : 5'd0);
        end
    end
endmodule
