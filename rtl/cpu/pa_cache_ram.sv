// Simple dual-port RAM for the caches: one read port whose address register
// loads when `ren` is high and holds otherwise (the data of the last
// enabled address stays on `rdata`), one write port; read-during-write of
// the same word returns the old data. Inferred as M10K; the 16K-deep arrays
// pack as 2K x 5 slices behind an output mux (docs/design/cpu-timing.md).
module pa_cache_ram #(
    parameter int WIDTH = 66,
    parameter int DEPTH_LOG2 = 14
) (
    input  logic                  clk,
    input  logic [DEPTH_LOG2-1:0] raddr,
    input  logic                  ren,
    output logic [WIDTH-1:0]      rdata,
    input  logic                  we,
    input  logic [DEPTH_LOG2-1:0] waddr,
    input  logic [WIDTH-1:0]      wdata
);
    (* ramstyle = "M10K, no_rw_check" *) logic [WIDTH-1:0] mem [1 << DEPTH_LOG2];
    logic [DEPTH_LOG2-1:0] raddr_q;
    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        if (ren) raddr_q <= raddr;
    end
    assign rdata = mem[raddr_q];
endmodule
