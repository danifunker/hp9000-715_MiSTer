// WAX (F020_0000-F020_7FFF) is not built (STUBS P-001). This stub takes
// the ROM's unconditional reset-time stores (HIL reset assert/negate at
// F020_1000 / F020_1C00) so they do not bus-error, and makes the presence
// probe -- a read of F020_0000 -- bus-error, so the ROM sees no WAX: it
// leaves LASI AMR = 2 and PDC_ADD_VALID drops the module (HW 6.1, 7).
// Everything else reads 0 (the 8042 status at F020_1801: IBF = 0).
module wax_stub (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        req,
    input  logic        we,
    input  logic [31:0] addr,
    output logic        ack,
    output logic        err,
    output logic [31:0] rdata
);
    always_ff @(posedge clk) begin
        ack <= 1'b0; err <= 1'b0;
        if (rst_n && req) begin
            ack <= 1'b1;
            rdata <= 32'd0;
            err <= !we && addr[14:2] == 13'd0;
        end
    end
endmodule
