// A PS/2 keyboard or mouse as the LASI port sees it, byte by byte (STUBS
// S-014): answers the host's commands the way the ROM, HP-UX and Linux
// expect (R06b 1: FA acks, AB 83 / 00 identification, AA after reset,
// resend on FE, the parameter byte of ED/F0/F3/F8-FD... commands, the set
// number after F0 00) and, while
// scanning is enabled, sends the keys and mouse movements from hps_io.
//
// Keys arrive in hps_io's ps2_key format ({toggle, pressed, extended,
// set-2 code}) and go out as scan code set 2 (E0 prefix, F0 break). HP-UX
// selects set 3 (F0 03); the model stores the selection and reports it, but
// still sends set 2 (STUBS S-014). Mouse packets come from hps_io's
// ps2_mouse ({toggle, dy, dx, buttons/flags}) in standard 3-byte format.
module ps2_dev #(
    parameter bit MOUSE      = 1'b0,
    parameter int BYTE_CLKS  = 64_000,      // spacing of the bytes it sends
    parameter int RESET_CLKS = 640_000      // reset to AA (BAT), ~10 ms
) (
    input  logic        clk,
    input  logic        rst,
    // host side (the LASI port)
    input  logic        tx_valid,           // a byte from the host
    input  logic [7:0]  tx_byte,
    output logic        rx_valid,           // a byte for the host
    output logic [7:0]  rx_byte,
    input  logic        rx_ready,
    // hps_io
    input  logic [10:0] ps2_key,
    input  logic [24:0] ps2_mouse
);
    // response queue
    logic [7:0] q [16];
    logic [3:0] q_rd, q_wr;
    logic [4:0] q_n;
    logic [7:0] last_sent;
    logic [19:0] gap;
    logic        scanning;
    logic [7:0]  pending_cmd;    // a command waiting for its parameter byte (0 = none)
    logic [1:0]  set;            // scan code set (stored only)
    logic        key_t, mouse_t;
    logic [19:0] bat;            // reset countdown, then AA (00)

    assign rx_valid = q_n != 5'd0 && gap == 20'd0;
    assign rx_byte  = q[q_rd];

    // enqueue up to three bytes this cycle
    logic [7:0] e0, e1, e2;
    logic [1:0] en;

    always_comb begin
        en = 2'd0; e0 = 8'd0; e1 = 8'd0; e2 = 8'd0;
        if (tx_valid) begin
            if (pending_cmd != 8'd0) begin
                en = 2'd1; e0 = 8'hFA;
                // F0 00 asks for the scan code set: FA, then 1, 2 or 3 (the
                // ROM's keyboard init sends F0 02, F0 00 and fails without it)
                if (pending_cmd == 8'hF0 && tx_byte == 8'h00 && !MOUSE) begin en = 2'd2; e1 = {6'd0, set}; end
            end
            else case (tx_byte)
                8'hFF: begin en = 2'd1; e0 = 8'hFA; end                       // reset: FA now, AA after BAT
                8'hFE: begin en = 2'd1; e0 = last_sent; end                   // resend
                8'hF2: if (MOUSE) begin en = 2'd2; e0 = 8'hFA; e1 = 8'h00; end
                       else begin en = 2'd3; e0 = 8'hFA; e1 = 8'hAB; e2 = 8'h83; end
                8'hEE: if (!MOUSE) begin en = 2'd1; e0 = 8'hEE; end
                       else begin en = 2'd1; e0 = 8'hFE; end
                8'hE9: if (MOUSE) begin en = 2'd3; e0 = 8'hFA; e1 = 8'h00; e2 = 8'h02; end   // status request
                       else begin en = 2'd1; e0 = 8'hFE; end
                8'hEB: begin en = 2'd1; e0 = 8'hFA; end                       // read data (mouse)
                default: begin en = 2'd1; e0 = 8'hFA; end
            endcase
        end else if (scanning && !MOUSE && ps2_key[10] != key_t) begin
            // a key from hps_io, in set 2
            if (ps2_key[8]) begin
                en = ps2_key[9] ? 2'd2 : 2'd3;
                e0 = 8'hE0; e1 = ps2_key[9] ? ps2_key[7:0] : 8'hF0; e2 = ps2_key[7:0];
            end else begin
                en = ps2_key[9] ? 2'd1 : 2'd2;
                e0 = ps2_key[9] ? ps2_key[7:0] : 8'hF0; e1 = ps2_key[7:0];
            end
        end else if (scanning && MOUSE && ps2_mouse[24] != mouse_t) begin
            en = 2'd3; e0 = ps2_mouse[7:0] | 8'h08;
            e1 = ps2_mouse[15:8]; e2 = ps2_mouse[23:16];
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            q_rd <= 4'd0; q_wr <= 4'd0; q_n <= 5'd0; gap <= 20'd0;
            scanning <= !MOUSE; pending_cmd <= 8'd0; set <= 2'd2; bat <= 20'd0;
            key_t <= ps2_key[10]; mouse_t <= ps2_mouse[24]; last_sent <= 8'hAA;
        end else begin
            logic pop;
            logic [4:0] room;
            pop = rx_valid && rx_ready;
            if (pop) begin q_rd <= q_rd + 4'd1; last_sent <= q[q_rd]; gap <= BYTE_CLKS[19:0]; end
            else if (gap != 20'd0) gap <= gap - 20'd1;

            if (!tx_valid) begin
                if (!MOUSE) key_t <= ps2_key[10];
                else mouse_t <= ps2_mouse[24];
            end
            room = 5'd16 - q_n;
            if (en != 2'd0 && room >= 5'd3) begin
                q[q_wr] <= e0;
                if (en >= 2'd2) q[q_wr + 4'd1] <= e1;
                if (en == 2'd3) q[q_wr + 4'd2] <= e2;
                q_wr <= q_wr + {2'd0, en};
            end
            q_n <= q_n + ((en != 2'd0 && room >= 5'd3) ? {3'd0, en} : 5'd0) - (pop ? 5'd1 : 5'd0);

            // commands and their parameter bytes
            if (tx_valid) begin
                if (pending_cmd != 8'd0) begin
                    if (pending_cmd == 8'hF0 && !MOUSE && tx_byte[1:0] != 2'd0) set <= tx_byte[1:0];
                    pending_cmd <= 8'd0;
                end else case (tx_byte)
                    8'hFF: begin scanning <= 1'b0; bat <= RESET_CLKS[19:0]; set <= 2'd2; end
                    8'hF5: scanning <= 1'b0;
                    8'hF4: scanning <= 1'b1;
                    8'hF6: begin scanning <= !MOUSE; set <= 2'd2; end
                    8'hED, 8'hF0, 8'hF3, 8'hFB, 8'hFC, 8'hFD, 8'hE8: pending_cmd <= tx_byte;
                    default: ;
                endcase
            end
            // the end of the self-test after a reset (waits a cycle if a
            // response is being queued in this one)
            if (bat != 20'd0 && !(bat == 20'd1 && (en != 2'd0 || room < 5'd3))) begin
                bat <= bat - 20'd1;
                if (bat == 20'd1) begin
                    q[q_wr] <= 8'hAA;
                    if (MOUSE) q[q_wr + 4'd1] <= 8'h00;
                    q_wr <= q_wr + (MOUSE ? 4'd2 : 4'd1);
                    q_n <= q_n + (MOUSE ? 5'd2 : 5'd1) - (pop ? 5'd1 : 5'd0);
                    if (!MOUSE) scanning <= 1'b1;
                end
            end
        end
    end
endmodule
