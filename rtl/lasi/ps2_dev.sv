// A PS/2 keyboard or mouse as the LASI port sees it, byte by byte (STUBS
// S-014): answers the host's commands the way the ROM, HP-UX and Linux
// expect -- a command first drops whatever is still queued, so its answer
// is the next byte the host sees (R06b 1: FA acks, AB 83 / 00 identification, AA after reset,
// resend on FE, the parameter byte of ED/F0/F3/F8-FD... commands, the set
// number after F0 00) and, while
// scanning is enabled, sends the keys and mouse movements from hps_io.
//
// Keys arrive in hps_io's ps2_key format ({toggle, pressed, extended,
// set-2 code}) and go out in the scan code set the host selected: set 2 (E0
// prefix, F0 break; also for a set-1 request) or set 3 (one code per key,
// F0 break; HP-UX selects it with F0 03), translated by set3() -- the IBM
// 101-key set-3 codes, as Linux's atkbd tables have them. Every key sends
// make and break whatever FA..FD asked for (HP-UX only asks make/break). Mouse
// packets come from hps_io's ps2_mouse ({toggle, dy, dx, buttons/flags}) in
// standard 3-byte format.
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
    input  logic [24:0] ps2_mouse,
    // a key event from the boot sequencer (rtl/boot_seq.sv), as a ps2_key one
    input  logic        inj_valid,
    input  logic        inj_down,
    input  logic [7:0]  inj_code,           // set-2 code, not extended
    output logic        q_empty             // nothing queued
);
    // response queue: 16 bytes in an MLAB, one write port, one read port
    // (rx_byte, which last_sent also takes). An answer's or an event's first
    // byte goes in at once, the others (at most two) wait in the staging
    // register s0/s1 and follow one a cycle -- long before the host may take
    // them, BYTE_CLKS apart -- so the host sees the same bytes at the same
    // times. While bytes are staged, an hps_io event waits (key_t/mouse_t
    // stay), a sequencer key waits in inj_p (also while the queue has no
    // room, or a host command is being answered: it follows the answer) and
    // so does the end of the self-test.
    localparam int GW = $clog2(BYTE_CLKS + 1);
    localparam int BW = $clog2(RESET_CLKS + 1);
    (* ramstyle = "MLAB, no_rw_check" *) logic [7:0] q [16];
    logic [3:0] q_rd, q_wr;
    logic [4:0] q_n;
    logic [7:0] s0, s1;          // staged bytes, s0 next
    logic [1:0] s_n;
    logic [7:0] last_sent;
    logic [GW-1:0] gap;
    logic        scanning;
    logic [7:0]  pending_cmd;    // a command waiting for its parameter byte (0 = none)
    logic [1:0]  set;            // scan code set (stored only)
    logic        key_t, mouse_t;
    logic        inj_p, inj_pd;  // a sequencer key waiting: pressed/released ...
    logic [7:0]  inj_pc;         // ... and its code
    logic [BW-1:0] bat;          // reset countdown, then AA (00)

    assign rx_valid = q_n != 5'd0 && gap == GW'(0);
    assign q_empty  = q_n == 5'd0 && s_n == 2'd0;
    assign rx_byte  = q[q_rd];

    // a set-2 key (E0 prefix or not) as its set-3 code; 0 = none
    function automatic logic [7:0] set3(input logic ext, input logic [7:0] k);
        if (ext) case (k)
            8'h11: return 8'h39;  8'h14: return 8'h58;                          // right Alt, right Ctrl
            8'h70: return 8'h67;  8'h6C: return 8'h6E;  8'h7D: return 8'h6F;    // Insert, Home, Page Up
            8'h71: return 8'h64;  8'h69: return 8'h65;  8'h7A: return 8'h6D;    // Delete, End, Page Down
            8'h75: return 8'h63;  8'h6B: return 8'h61;  8'h72: return 8'h60;  8'h74: return 8'h6A;   // arrows
            8'h4A: return 8'h77;  8'h5A: return 8'h79;                          // keypad /, keypad Enter
            8'h7C: return 8'h57;  8'h77, 8'h7E: return 8'h62;                   // Print Screen, Pause/Break
            8'h1F: return 8'h8B;  8'h27: return 8'h8C;  8'h2F: return 8'h8D;    // Windows, Windows, Menu
            default: return 8'h00;
        endcase
        case (k)
            8'h76: return 8'h08;                                                // Esc
            8'h05: return 8'h07;  8'h06: return 8'h0F;  8'h04: return 8'h17;  8'h0C: return 8'h1F;   // F1-F4
            8'h03: return 8'h27;  8'h0B: return 8'h2F;  8'h83: return 8'h37;  8'h0A: return 8'h3F;   // F5-F8
            8'h01: return 8'h47;  8'h09: return 8'h4F;  8'h78: return 8'h56;  8'h07: return 8'h5E;   // F9-F12
            8'h7E: return 8'h5F;                                                // Scroll Lock
            8'h5D: return 8'h5C;  8'h61: return 8'h13;                          // backslash, the ISO key
            8'h58: return 8'h14;  8'h14: return 8'h11;  8'h11: return 8'h19;    // Caps Lock, left Ctrl, left Alt
            8'h77: return 8'h76;  8'h7C: return 8'h7E;  8'h7B: return 8'h84;  8'h79: return 8'h7C;   // Num Lock, keypad * - +
            default: return k;    // letters, digits, punctuation, Space, Tab, Enter, BS, shifts, keypad digits
        endcase
    endfunction
    // the key event being queued: the sequencer's (waiting, or this cycle's;
    // never dropped while scanning) before hps_io's
    wire        ij_v    = inj_p || inj_valid;
    wire        kv_ext  = ij_v ? 1'b0 : ps2_key[8];
    wire        kv_down = inj_p ? inj_pd : inj_valid ? inj_down : ps2_key[9];
    wire [7:0]  kv_code = inj_p ? inj_pc : inj_valid ? inj_code : ps2_key[7:0];
    wire [7:0] k3 = set3(kv_ext, kv_code);

    // the bytes to queue this cycle (up to three)
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
        end else if (scanning && !MOUSE && (ij_v || ps2_key[10] != key_t)) begin
            // a key from hps_io (or the boot sequencer), in the selected set
            if (set == 2'd3) begin
                if (k3 != 8'h00) begin
                    en = kv_down ? 2'd1 : 2'd2;
                    e0 = kv_down ? k3 : 8'hF0; e1 = k3;
                end
            end else if (kv_ext) begin
                en = kv_down ? 2'd2 : 2'd3;
                e0 = 8'hE0; e1 = kv_down ? kv_code : 8'hF0; e2 = kv_code;
            end else begin
                en = kv_down ? 2'd1 : 2'd2;
                e0 = kv_down ? kv_code : 8'hF0; e1 = kv_code;
            end
        end else if (scanning && MOUSE && ps2_mouse[24] != mouse_t) begin
            en = 2'd3; e0 = ps2_mouse[7:0] | 8'h08;
            e1 = ps2_mouse[15:8]; e2 = ps2_mouse[23:16];
        end
    end

    // what goes into the queue this cycle: an answer (always, the queue
    // flushed), an event (with nothing staged and room for three), the next
    // staged byte, or AA at the end of the self-test (waits a cycle if a
    // response is being queued or staged in this one; the mouse's 00 staged)
    wire [4:0] room    = 5'd16 - q_n;
    wire       ev_go   = !tx_valid && s_n == 2'd0;      // an event is decided this cycle
    wire       take    = ev_go && en != 2'd0 && room >= 5'd3;
    wire       bat_end = bat == BW'(1) && en == 2'd0 && s_n == 2'd0 && room >= 5'd3;
    wire       q_we    = tx_valid || take || s_n != 2'd0 || bat_end;
    wire [7:0] q_wd    = (tx_valid || take) ? e0 : s_n != 2'd0 ? s0 : 8'hAA;
    always_ff @(posedge clk) if (q_we) q[q_wr] <= q_wd;

    always_ff @(posedge clk) begin
        if (rst) begin
            q_rd <= 4'd0; q_wr <= 4'd0; q_n <= 5'd0; s_n <= 2'd0; gap <= GW'(0);
            scanning <= !MOUSE; pending_cmd <= 8'd0; set <= 2'd2; bat <= BW'(0);
            key_t <= ps2_key[10]; mouse_t <= ps2_mouse[24]; last_sent <= 8'hAA; inj_p <= 1'b0;
        end else begin
            logic pop;
            pop = rx_valid && rx_ready;
            if (pop) begin q_rd <= q_rd + 4'd1; last_sent <= rx_byte; gap <= GW'(BYTE_CLKS); end
            else if (gap != GW'(0)) gap <= gap - GW'(1);

            if (ev_go) begin
                if (!MOUSE && !ij_v) key_t <= ps2_key[10];
                else mouse_t <= ps2_mouse[24];
            end
            // a sequencer key waits until it is queued, or dropped because
            // scanning is off (or set 3 has no code for it); one waits at most
            // a few clocks and they come KEY_MS apart (rtl/boot_seq.sv), so a
            // second one never finds it still waiting unless the host stops
            // reading with the queue full -- that second one is dropped
            if (!inj_p && inj_valid) begin inj_pd <= inj_down; inj_pc <= inj_code; end
            inj_p <= !MOUSE && ij_v && !(ev_go && (en == 2'd0 || room >= 5'd3));
`ifdef SIMULATION
            if (inj_p && inj_valid) $display("ps2_dev: a sequencer key while one still waits, dropped");
`endif
            if (q_we) q_wr <= q_wr + 4'd1;
            if (tx_valid) begin
                // a command from the host: like a real keyboard or mouse,
                // the device drops what it has not sent yet and answers at
                // once (keys typed while HP-UX's X server set the keyboard
                // up came before its acknowledgements, and X gave up)
                q_rd <= q_wr;
                q_n <= 5'd1;
            end else
                q_n <= q_n + (q_we ? 5'd1 : 5'd0) - (pop ? 5'd1 : 5'd0);
            if (tx_valid || take) begin s0 <= e1; s1 <= e2; s_n <= en - 2'd1; end
            else if (s_n != 2'd0) begin s0 <= s1; s_n <= s_n - 2'd1; end
            else if (bat_end && MOUSE) begin s0 <= 8'h00; s_n <= 2'd1; end

            // commands and their parameter bytes
            if (tx_valid) begin
                if (pending_cmd != 8'd0) begin
                    if (pending_cmd == 8'hF0 && !MOUSE && tx_byte[1:0] != 2'd0) set <= tx_byte[1:0];
                    pending_cmd <= 8'd0;
                end else case (tx_byte)
                    8'hFF: begin scanning <= 1'b0; bat <= BW'(RESET_CLKS); set <= 2'd2; end
                    8'hF5: scanning <= 1'b0;
                    8'hF4: scanning <= 1'b1;
                    8'hF6: begin scanning <= !MOUSE; set <= 2'd2; end
                    8'hED, 8'hF0, 8'hF3, 8'hFB, 8'hFC, 8'hFD, 8'hE8: pending_cmd <= tx_byte;
                    default: ;
                endcase
            end
            // the end of the self-test after a reset (AA queued by bat_end)
            if (bat != BW'(0) && (bat != BW'(1) || bat_end)) begin
                bat <= bat - BW'(1);
                if (bat == BW'(1) && !MOUSE) scanning <= 1'b1;
            end
        end
    end
endmodule
