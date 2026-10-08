// One LASI PS/2 port (Lasi ERS 9; HW 4.7; docs/review/06b 1). Registers at
// word stride, byte-wide: +0 ID (R) / RESET (W), +4 RCVDATA / XMTDATA,
// +8 CONTROL, +C STATUS. 4-character RX FIFO, 1-character TX buffer.
//
// The device side is byte-level, not the PS/2 wire protocol (STUBS S-014):
// a transmitted byte is handed to the device model `BYTE_CLKS` clocks after
// it starts, the device hands bytes back whenever the port can take one
// (enabled, not inhibited, FIFO not full, not transmitting). With
// `dev_present` = 0 a transmission never finishes, so TBNE stays 1, as the
// real port does with nothing on the connector (HP-UX relies on it).
// Loopback (CONTROL.LPBXR) sends the byte to the port's own receiver in 11
// bit times of the ERS's 2 MHz clock; while the FIFO is full the byte waits.
module lasi_ps2 #(
    parameter logic [3:0] ID        = 4'd0,     // 0 keyboard, 1 mouse
    parameter int         BYTE_CLKS = 64_000,   // one character on the wire (~1 ms)
    parameter int         LPB_CLKS  = 352       // one character in loopback (11 bits at 2 MHz)
) (
    input  logic       clk,
    input  logic       rst,
    input  logic       sel,
    input  logic       we,
    input  logic [1:0] ra,          // word register 0..3
    input  logic [7:0] wdata,
    output logic [7:0] rdata,
    input  logic       cmpintr,     // OR of all ports' interrupt lines
    output logic       irq_line,    // this port's line: RBNE while enabled
    // device side
    input  logic       dev_present,
    output logic       dev_tx_valid,
    output logic [7:0] dev_tx_byte,
    input  logic       dev_rx_valid,
    input  logic [7:0] dev_rx_byte,
    output logic       dev_rx_ready
);
    logic [7:0]  ctrl;
    logic [7:0]  fifo [4];
    logic [1:0]  f_rd, f_wr;
    logic [2:0]  f_n;
    logic        tbne;
    logic [7:0]  tbuf;
    logic        txing;
    logic [16:0] tcnt;

    wire enbl   = ctrl[0];
    wire lpbk   = ctrl[1];
    wire inhib  = ctrl[5] && !ctrl[7];      // DIAG with the clock line forced low
    wire f_full = f_n == 3'd4;
    assign irq_line = enbl && f_n != 3'd0;
    assign dev_rx_ready = enbl && !lpbk && !inhib && !f_full && !txing && !tbne;
    assign dev_tx_byte = tbuf;

    always_comb begin
        case (ra)
            2'd0: rdata = {4'd0, ID};
            2'd1: rdata = fifo[f_rd];
            2'd2: rdata = ctrl;
            // CLKSHD, DATSHD (the idle lines read 1 unless DIAG drives them), CMPINTR, TBNE, RBNE
            default: rdata = {ctrl[5] ? ctrl[7] : 1'b1, ctrl[5] ? ctrl[6] : 1'b1, 1'b0, cmpintr,
                              2'b00, tbne, f_n != 3'd0};
        endcase
    end

    wire rd_data = sel && !we && ra == 2'd1;
    wire wr_data = sel && we && ra == 2'd1;

    always_ff @(posedge clk) begin
        dev_tx_valid <= 1'b0;
        if (rst || (sel && we && ra == 2'd0)) begin
            // interface reset: buffers emptied, state machines reset, disabled
            ctrl <= 8'd0; f_rd <= 2'd0; f_wr <= 2'd0; f_n <= 3'd0;
            tbne <= 1'b0; txing <= 1'b0; tcnt <= 17'd0;
        end else begin
            logic push, pop;
            logic [7:0] pbyte;
            push = 1'b0; pbyte = 8'd0;
            pop  = rd_data && f_n != 3'd0;

            if (sel && we && ra == 2'd2) ctrl <= wdata;
            if (wr_data && !tbne) begin tbne <= 1'b1; tbuf <= wdata; end

            // transmitter: start when enabled (a byte written while disabled waits)
            if (tbne && !txing && enbl && !inhib && (!lpbk || !f_full) && (lpbk || dev_present)) begin
                txing <= 1'b1; tcnt <= 17'd0;
            end
            if (txing) begin
                tcnt <= tcnt + 17'd1;
                if (tcnt == 17'((lpbk ? LPB_CLKS : BYTE_CLKS) - 1)) begin
                    txing <= 1'b0; tbne <= 1'b0;
                    if (lpbk) begin push = 1'b1; pbyte = tbuf; end
                    else dev_tx_valid <= 1'b1;
                end
            end
            // receiver: a byte from the device
            if (dev_rx_valid && dev_rx_ready) begin push = 1'b1; pbyte = dev_rx_byte; end

            if (push && (!f_full || pop)) begin fifo[f_wr] <= pbyte; f_wr <= f_wr + 2'd1; end
            if (pop) f_rd <= f_rd + 2'd1;
            f_n <= f_n + ((push && (!f_full || pop)) ? 3'd1 : 3'd0) - (pop ? 3'd1 : 3'd0);
        end
    end
endmodule
