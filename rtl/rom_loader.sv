// The boot ROM download (docs/design/system.md 8): hps_io's ioctl stream
// (WIDE mode, the earlier byte in the low half of ioctl_dout) assembled into
// big-endian 64-bit words for the ROM store, with the one-word patch of
// STUBS S-011 applied on the way: file offset 0xB810 0x86802012 (`cmpib,=,n
// 0,r20`: skip the dual-issue timing test 0x4108D only at CPU revision 0)
// becomes 0xE8000012 (`b,l,n` over it) -- only if the word is the expected
// one, so another image passes untouched.
module rom_loader #(
    parameter logic [7:0] INDEX     = 8'd0,
    parameter bit         PATCH_S011 = 1'b1
) (
    input  logic        clk,
    input  logic        ioctl_download,
    input  logic        ioctl_wr,
    input  logic [24:0] ioctl_addr,
    input  logic [15:0] ioctl_dout,
    input  logic [7:0]  ioctl_index,
    output logic        busy,          // a ROM download is running
    output logic        wr,            // one doubleword
    output logic [17:3] waddr,
    output logic [63:0] wdata
);
    wire mine = ioctl_index == INDEX;
    logic        dl_q;
    logic [63:0] acc;
    logic [17:3] acc_addr;
    logic        acc_any;

    assign busy = ioctl_download && mine;

    function automatic logic [63:0] patch(input logic [63:0] d, input logic [17:3] a);
        if (PATCH_S011 && a == 15'h1702 && d[63:32] == 32'h8680_2012) return {32'hE800_0012, d[31:0]};
        return d;
    endfunction

    always_ff @(posedge clk) begin
        wr <= 1'b0;
        dl_q <= busy;
        if (busy && ioctl_wr) begin
            logic [63:0] n;
            n = acc;
            n[63 - 16*ioctl_addr[2:1] -: 16] = {ioctl_dout[7:0], ioctl_dout[15:8]};
            acc <= n; acc_addr <= ioctl_addr[17:3]; acc_any <= 1'b1;
            if (ioctl_addr[2:1] == 2'd3) begin
                wr <= 1'b1; waddr <= ioctl_addr[17:3]; wdata <= patch(n, ioctl_addr[17:3]);
                acc <= 64'd0; acc_any <= 1'b0;
            end
        end
        if (busy && !dl_q) begin acc <= 64'd0; acc_any <= 1'b0; end
        if (!busy && dl_q && acc_any) begin           // a file that does not end on 8 bytes
            wr <= 1'b1; waddr <= acc_addr; wdata <= patch(acc, acc_addr); acc_any <= 1'b0;
        end
    end
endmodule
