// The OSD's "Boot mode": a keystroke sequencer that stops the ROM's
// autoboot and types the boot commands for the user (2026-10-14; STUBS
// S-029). It is sticky: it runs after every reset until the mode is Normal.
//
// How it knows the firmware is waiting at a prompt: the ROM and ISL poll the
// console input -- the LASI UART's LSR/RBR, or PS/2 port 0's status/data --
// with nothing to read. A run of POLLS such reads spread over at least
// EPISODE_MS, none more than GAP_MS after the previous, with no byte taken
// from that input and nothing sent on it (the ROM's transmit polls the same
// LSR) meanwhile, is an "episode": the firmware is at a prompt (the ESC
// countdown, BOOT_ADMIN>, ISL>). The
// sequencer then types the next command of the mode's script on the input
// being polled, waits until every byte has been taken (the UART's receive
// FIFO empty; the keyboard model's queue and the port's FIFO empty), and
// waits for the next episode. After the script's last command it stops until
// the next reset, so it never types into a running operating system.
//
//   mode 0 Normal          nothing
//        1 BOOT_ADMIN      ESC
//        2 ISL             ESC, "boot pri isl"
//        3 single-user     ESC, "boot pri isl", "hpux -is"
//        4 LVM maintenance ESC, "boot pri isl", "hpux -lm"
//        5 network         ESC, "boot lan"
//        6 CD/DVD          ESC, "boot scsi.2"
//
// Typing on the keyboard: hps_io-style key events (set-2 code, pressed /
// released) into the keyboard model (rtl/lasi/ps2_dev.sv inj_*), one every
// KEY_MS; on the UART: bytes into its receive FIFO (lasi_uart inj_*).
module boot_seq #(
    parameter int CLK_HZ     = 64_000_000,
    parameter bit SIM_FAST   = 1'b0,
    parameter int POLLS      = 32,          // idle polls that make an episode ...
    parameter int EPISODE_MS = 20,          // ... spread over at least this long
    parameter int GAP_MS     = 50,          // ... with no gap longer than this
    parameter int KEY_MS     = 4            // a key event (press or release) every KEY_MS
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic [2:0] mode,
    input  logic [7:0] chassis,             // the ROM's chassis code (bits 19:12, from the LED latch): which phase the firmware is in
    input  logic [3:0] ms_mul,              // the simulator's CR16 speed-up (0 on the board): the millisecond follows it
    // the UART (rtl/lasi/lasi.sv con_*): a poll = an LSR or RBR read with the
    // receive FIFO empty; a take = an RBR read with data
    input  logic       uart_poll, uart_take, uart_rx_empty, uart_tx,   // poll: lasi_uart con_poll (an MSR read, the IODC's input routine)
    output logic       uart_inj_strobe,
    output logic [7:0] uart_inj_byte,
    input  logic       uart_inj_full,
    // PS/2 port 0: a poll = a status or data read with the port's FIFO empty;
    // a take = a data read with data; kbd_idle = the keyboard model's queue
    // and the port's FIFO are empty
    input  logic       kbd_poll, kbd_take, kbd_idle, kbd_tx,
    output logic       key_valid,           // one-cycle strobe: a key event
    output logic       key_down,
    output logic [7:0] key_code,            // set-2 code (never extended)
    output logic       active                // the sequencer still has commands to type
);
    // a millisecond of the firmware's time: real on the board; in the simulator
    // the ROM's waits run ms_mul times faster (romsim --turbo), so does this
    localparam int MS = CLK_HZ / 1000;
    wire [15:0] ms_lim = ms_mul == 4'd0 ? 16'(MS - 1) : 16'(MS / ms_mul - 1);

    // ------------------------------------------------------------ the script
    // step s of mode m, character i (0 = end of the step; step 0 is ESC)
    function automatic logic [7:0] str_c(input logic [3:0] which, input logic [3:0] i);
        case (which)
            4'd1: case (i)                    // "boot pri isl\r"
                4'd0: return "b"; 4'd1: return "o"; 4'd2: return "o"; 4'd3: return "t"; 4'd4: return " ";
                4'd5: return "p"; 4'd6: return "r"; 4'd7: return "i"; 4'd8: return " ";
                4'd9: return "i"; 4'd10: return "s"; 4'd11: return "l"; 4'd12: return 8'h0D;
                default: return 8'd0; endcase
            4'd2: case (i)                    // "hpux -is\r"
                4'd0: return "h"; 4'd1: return "p"; 4'd2: return "u"; 4'd3: return "x"; 4'd4: return " ";
                4'd5: return "-"; 4'd6: return "i"; 4'd7: return "s"; 4'd8: return 8'h0D;
                default: return 8'd0; endcase
            4'd3: case (i)                    // "hpux -lm\r"
                4'd0: return "h"; 4'd1: return "p"; 4'd2: return "u"; 4'd3: return "x"; 4'd4: return " ";
                4'd5: return "-"; 4'd6: return "l"; 4'd7: return "m"; 4'd8: return 8'h0D;
                default: return 8'd0; endcase
            4'd4: case (i)                    // "boot lan\r"
                4'd0: return "b"; 4'd1: return "o"; 4'd2: return "o"; 4'd3: return "t"; 4'd4: return " ";
                4'd5: return "l"; 4'd6: return "a"; 4'd7: return "n"; 4'd8: return 8'h0D;
                default: return 8'd0; endcase
            4'd5: case (i)                    // "boot scsi.2\r"
                4'd0: return "b"; 4'd1: return "o"; 4'd2: return "o"; 4'd3: return "t"; 4'd4: return " ";
                4'd5: return "s"; 4'd6: return "c"; 4'd7: return "s"; 4'd8: return "i"; 4'd9: return ".";
                4'd10: return "2"; 4'd11: return 8'h0D;
                default: return 8'd0; endcase
            default: return i == 4'd0 ? 8'h1B : 8'd0;    // step 0: ESC
        endcase
    endfunction
    // the chassis code each step waits for: the ROM's boot decision and BOOT_ADMIN are 0x43 (BOOTFLOW.md 2.8:
    // 0x4300C/0x4300B; the keyboard is polled long before that, during the self-tests, so a prompt
    // detected under another code is not the ESC window); ISL's prompt leaves the ROM's last code
    localparam logic [7:0] CODE_ROM = 8'h43;
    localparam logic [7:0] CODE_ISL = 8'h0C;      // ISL's own code (romsim: `LED 0C` just before `ISL>`)
    function automatic logic step_phase(input logic [1:0] s, input logic [7:0] c);
        return s == 2'd2 ? c == CODE_ISL : c == CODE_ROM;
    endfunction
    // which string each step of a mode types (0 = ESC; 15 = no such step)
    function automatic logic [3:0] step_str(input logic [2:0] m, input logic [1:0] s);
        case (s)
            2'd0: return m == 3'd0 ? 4'd15 : 4'd0;
            2'd1: case (m) 3'd2, 3'd3, 3'd4: return 4'd1; 3'd5: return 4'd4; 3'd6: return 4'd5; default: return 4'd15; endcase
            2'd2: case (m) 3'd3: return 4'd2; 3'd4: return 4'd3; default: return 4'd15; endcase
            default: return 4'd15;
        endcase
    endfunction
    // ASCII -> set-2 scan code (US layout; only what the script needs)
    function automatic logic [7:0] set2(input logic [7:0] c);
        case (c)
            "a": return 8'h1C; "b": return 8'h32; "c": return 8'h21; "d": return 8'h23; "e": return 8'h24;
            "f": return 8'h2B; "g": return 8'h34; "h": return 8'h33; "i": return 8'h43; "j": return 8'h3B;
            "k": return 8'h42; "l": return 8'h4B; "m": return 8'h3A; "n": return 8'h31; "o": return 8'h44;
            "p": return 8'h4D; "q": return 8'h15; "r": return 8'h2D; "s": return 8'h1B; "t": return 8'h2C;
            "u": return 8'h3C; "v": return 8'h2A; "w": return 8'h1D; "x": return 8'h22; "y": return 8'h35;
            "z": return 8'h1A;
            "0": return 8'h45; "1": return 8'h16; "2": return 8'h1E; "3": return 8'h26; "4": return 8'h25;
            "5": return 8'h2E; "6": return 8'h36; "7": return 8'h3D; "8": return 8'h3E; "9": return 8'h46;
            " ": return 8'h29; "-": return 8'h4E; ".": return 8'h49; 8'h0D: return 8'h5A; 8'h1B: return 8'h76;
            default: return 8'h29;
        endcase
    endfunction

    // ------------------------------------------------------------ episodes
    // per input: idle polls since the last take, and the time since the first
    logic [5:0]  u_polls, k_polls;
    logic [7:0]  u_ms, k_ms, u_gap, k_gap;
    logic [15:0] ms_div;
`ifdef SIMULATION
    longint dbg_cyc = 0;
    always_ff @(posedge clk) dbg_cyc <= dbg_cyc + 1;
`endif
    logic        ms;
    wire         u_episode = u_polls == 6'(POLLS) && u_ms >= 8'(EPISODE_MS);
    wire         k_episode = k_polls == 6'(POLLS) && k_ms >= 8'(EPISODE_MS) && kbd_idle;

    typedef enum logic [1:0] { S_WAIT, S_TYPE, S_DRAIN, S_DONE } st_e;
    st_e         st;
    logic [1:0]  step;
    logic        on_kbd;                    // the current step types on the keyboard
    logic [3:0]  ci;                        // character index
    logic        key_phase;                 // 0 = press next, 1 = release next
    logic [7:0]  key_ms;
    wire  [3:0]  cur_str = step_str(mode, step);
    wire  [7:0]  cur_c   = str_c(cur_str, ci);
    assign active = st != S_DONE && mode != 3'd0;

    always_ff @(posedge clk) begin
        uart_inj_strobe <= 1'b0; key_valid <= 1'b0;
        ms <= 1'b0;
        if (ms_div >= ms_lim) begin ms_div <= 16'd0; ms <= 1'b1; end else ms_div <= ms_div + 16'd1;

        // the episode detectors
        if (uart_take || !uart_rx_empty || uart_tx || u_gap >= 8'(GAP_MS)) begin u_polls <= 6'd0; u_ms <= 8'd0; u_gap <= 8'd0; end
        else begin
            if (uart_poll) begin u_gap <= 8'd0; if (u_polls != 6'(POLLS)) u_polls <= u_polls + 6'd1; end
            else if (ms && u_polls != 6'd0) u_gap <= u_gap + 8'd1;
            if (ms && u_polls != 6'd0 && u_ms != 8'hFF) u_ms <= u_ms + 8'd1;
        end
        if (kbd_take || !kbd_idle || kbd_tx || k_gap >= 8'(GAP_MS)) begin k_polls <= 6'd0; k_ms <= 8'd0; k_gap <= 8'd0; end
        else begin
            if (kbd_poll) begin k_gap <= 8'd0; if (k_polls != 6'(POLLS)) k_polls <= k_polls + 6'd1; end
            else if (ms && k_polls != 6'd0) k_gap <= k_gap + 8'd1;
            if (ms && k_polls != 6'd0 && k_ms != 8'hFF) k_ms <= k_ms + 8'd1;
        end
        if (ms && key_ms != 8'hFF) key_ms <= key_ms + 8'd1;

        if (!rst_n) begin
            st <= S_WAIT; step <= 2'd0; ci <= 4'd0; key_phase <= 1'b0; key_ms <= 8'd0; on_kbd <= 1'b0;
            u_polls <= 6'd0; u_ms <= 8'd0; k_polls <= 6'd0; k_ms <= 8'd0; u_gap <= 8'd0; k_gap <= 8'd0; ms_div <= 16'd0;
        end else case (st)
            S_WAIT: begin
                if (cur_str == 4'd15) st <= S_DONE;
                else if ((k_episode || u_episode) && step_phase(step, chassis)) begin
                    on_kbd <= k_episode; ci <= 4'd0; key_phase <= 1'b0; key_ms <= 8'd0;
                    st <= S_TYPE;
`ifdef SIMULATION
                    $display("boot_seq: prompt on the %s, typing step %0d of mode %0d (cycle %0d)", k_episode ? "keyboard" : "UART", step, mode, dbg_cyc);
`endif
                end
            end
            S_TYPE: begin
                if (cur_c == 8'd0) st <= S_DRAIN;
                else if (on_kbd) begin
                    if (key_ms >= 8'(KEY_MS)) begin
                        key_valid <= 1'b1; key_down <= !key_phase; key_code <= set2(cur_c);
                        key_ms <= 8'd0; key_phase <= !key_phase;
                        if (key_phase) ci <= ci + 4'd1;
                    end
                end else if (!uart_inj_full && uart_rx_empty && key_ms >= 8'd1) begin
                    // one byte at a time, as a serial line would (the ROM runs the
                    // UART without its FIFO: a second byte would be an overrun)
                    uart_inj_strobe <= 1'b1; uart_inj_byte <= cur_c;
                    ci <= ci + 4'd1; key_ms <= 8'd0;
                end
            end
            // every byte taken by the firmware (so the next episode is a new prompt);
            // key_ms: the last byte has had time to reach the FIFO
            S_DRAIN: if (key_ms >= 8'd2 && (on_kbd ? kbd_idle : uart_rx_empty)) begin
`ifdef SIMULATION
                $display("boot_seq: step %0d taken", step);
`endif
                step <= step + 2'd1;
                u_polls <= 6'd0; u_ms <= 8'd0; k_polls <= 6'd0; k_ms <= 8'd0; u_gap <= 8'd0; k_gap <= 8'd0;
                st <= S_WAIT;
            end
            default: ;
        endcase
    end
endmodule
