// System RAM on the MiSTer SDRAM module (docs/design/system.md 3.3, 7):
// the machine's RAM port -- 32-byte lines and single doublewords with byte
// enables, big-endian -- on a 16-bit SDR SDRAM, on the machine's own clock
// (no clock crossing; at 64 MHz every SDRAM timing is two or three cycles).
//
// Geometry (the Quadra core's mapping, which fits every MiSTer module):
// byte address A[26:0]; rank = A[26] (the 128 MB module's two 64 MB ranks:
// nCS low selects rank 0 and, inverted on the module, high selects rank 1),
// bank = A[24:23], row = A[22:10], column = {A[25], A[9:1]} (A[25] is
// ignored by the 32 MB parts' 9-bit columns). A doubleword is four columns,
// the first one holding bits 63:48 (big-endian: the even byte on DQ[15:8]).
//
// Every access is ACTIVE, then one or two BL8 bursts (CAS latency 2,
// sequential, write bursts on), the last one with auto-precharge: a closed
// page, no open-row bookkeeping. A line is two bursts: the half holding the
// requested doubleword first, so the beats come critical-first in burst
// order (c, c^1, c^2, c^3; ram_rbeat names each). A single doubleword is
// one burst whose other four words are masked (writes) or ignored (reads).
// Writes collect their beats from the port before the ACTIVE.
//
// Read timing: a READ in the command register in cycle c reaches the chip at
// the edge ending c (SDRAM_CLK in phase with clk), data comes CL cycles
// later and is registered at the pins one edge after that: word w is in
// dq_in during cycle c + RD_LAT + w. RD_LAT = 4 for CL 2 with SDRAM_CLK in
// phase; the simulator's chip model (verilator/tb/tb_sdram64.sv) has that
// pipeline.
//
// On the board SDRAM_CLK is the 270-degree PLL output (STUBS S-019) and
// the data window moves, so the capture point is chosen at run time
// (rd_mode, an OSD option). Measured on the board (2026-10-08, build 3,
// the ROM's LFSR memory test, edges counted from the one that launches the
// READ): with builds 3 and 4, edges 2.75 (clk_sdram) and 3 read correctly;
// 2.5 (a clean pipeline in build 4), 3.5 and 4 do not (3.5 and 4 read every
// 16-bit beat one beat late). So the window opens after 2.5 and closes
// before 3.5, and edge 3 -- a plain rising-edge register -- is the default.
// Word k is taken when rw = 2 + L + k:
//   rd_mode 0: clk edge 3,            L = RD_LAT - 1   -- the default
//   rd_mode 1: clk_sdram edge (2.75), re-registered into clk 3.9 ns later,
//              L = RD_LAT - 1
//   rd_mode 2: falling edge 2.5 (re-registered at 3), L = RD_LAT - 1
//   rd_mode 3: clk edge 4,            L = RD_LAT       -- the bench's chip
//              model (SDRAM_CLK in phase); one beat late on the board
module sdram64 #(
    parameter int CLK_HZ = 64_000_000,
    parameter int RD_LAT = 4
) (
    input  logic        clk,
    input  logic        clk_sdram,      // SDRAM_CLK's source: clk + 270 degrees
    input  logic        rst,
    input  logic [1:0]  rd_mode,        // read capture point (above)
    output logic        ready,          // initialised
    // the machine's RAM port (rtl/mioc.sv)
    input  logic        ram_req,
    input  logic        ram_we,
    input  logic        ram_line,
    input  logic [26:0] ram_addr,
    input  logic [7:0]  ram_be,
    input  logic [63:0] ram_wdata,
    output logic        ram_ack,
    output logic        ram_wready,
    output logic        ram_rvalid,
    output logic [1:0]  ram_rbeat,
    output logic [63:0] ram_rdata,
    // SDRAM pins (SDRAM_CLK comes from the top, in phase with clk)
    inout  wire  [15:0] SDRAM_DQ,
    output logic [12:0] SDRAM_A,
    output logic [1:0]  SDRAM_BA,
    output logic        SDRAM_DQML,
    output logic        SDRAM_DQMH,
    output logic        SDRAM_nCS,
    output logic        SDRAM_nRAS,
    output logic        SDRAM_nCAS,
    output logic        SDRAM_nWE,
    output logic        SDRAM_CKE
);
    localparam logic [2:0] C_NOP = 3'b111, C_ACT = 3'b011, C_RD = 3'b101, C_WR = 3'b100,
                           C_PRE = 3'b010, C_REF = 3'b001, C_MRS = 3'b000;
    // burst length 8, sequential, CAS latency 2, write bursts on
    localparam logic [12:0] MODE = 13'b000_0_00_010_0_011;
    localparam int INIT_WAIT = CLK_HZ / 10_000 + 100;     // 100 us + a margin
    localparam int REF_EVERY = CLK_HZ / 1_000_000 * 76 / 10;   // 7.6 us (8192 rows / 64 ms)

    // pins: everything registered
    logic [2:0]  cmd;
    logic        chip;
    logic [15:0] dq_out, dq_in;
    logic        dq_oe;
    logic [1:0]  dqm;
    assign {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd;
    assign SDRAM_nCS = chip;
    assign {SDRAM_DQMH, SDRAM_DQML} = dqm;
    assign SDRAM_CKE = 1'b1;
    assign SDRAM_DQ  = dq_oe ? dq_out : 16'hZZZZ;
    // the three samples, each a plain register in clk afterwards
    logic [15:0] dq_in_s, dq_in_sq, dq_in_n, dq_in_nq;
    always_ff @(posedge clk_sdram) dq_in_s <= SDRAM_DQ;
    always_ff @(negedge clk) dq_in_n <= SDRAM_DQ;
    always_ff @(posedge clk) begin
        dq_in <= SDRAM_DQ;
        dq_in_sq <= dq_in_s;
        dq_in_nq <= dq_in_n;
    end
    logic [4:0]  rd_first;        // rw of the first read word: 2 + L
    logic [1:0]  rd_m;
    always_ff @(posedge clk) begin
        rd_m <= rd_mode;
        rd_first <= rd_mode == 2'd3 ? 5'(2 + RD_LAT) : 5'(2 + RD_LAT - 1);
    end
    wire [15:0] dq_cap = rd_m == 2'd1 ? dq_in_sq : rd_m == 2'd2 ? dq_in_nq : dq_in;

    typedef enum logic [3:0] {
        S_INIT, S_INIT_SEQ, S_IDLE, S_REF, S_WCOLL, S_ACT, S_RW, S_WAIT
    } st_e;
    st_e st;

    logic [15:0] tcnt;            // a general countdown
    logic [4:0]  iseq;            // init sequence step
    logic [9:0]  ref_cnt;
    logic        ref_due;
    logic        r_we, r_line;
    logic [26:0] r_addr;
    logic [7:0]  r_be;
    logic [63:0] wbuf [4];
    logic [2:0]  wn;              // write beats collected
    logic [4:0]  rw;              // cycle within the burst phase
    // read capture
    logic [1:0]  cw;              // word within the doubleword being assembled
    logic [47:0] asm_w;
    logic [1:0]  crit;

    wire [1:0] c0 = r_addr[4:3];
    // column of a burst starting at doubleword d of the line
    function automatic logic [12:0] col_of(input logic [1:0] d, input logic ap);
        return {2'b00, ap, r_addr[25], r_addr[9:5], d, 2'b00};
    endfunction
    // the 16-bit word w (0..3) of a doubleword, and its write mask
    function automatic logic [15:0] word_of(input logic [63:0] q, input logic [1:0] w);
        return q[63 - 16*w -: 16];
    endfunction

    always_ff @(posedge clk) begin
        cmd <= C_NOP; dq_oe <= 1'b0; dqm <= 2'b00;
        ram_ack <= 1'b0; ram_wready <= 1'b0; ram_rvalid <= 1'b0;
        if (ref_cnt == 10'(REF_EVERY)) begin ref_cnt <= 10'd0; ref_due <= 1'b1; end
        else ref_cnt <= ref_cnt + 10'd1;

        if (rst) begin
            st <= S_INIT; tcnt <= 16'(INIT_WAIT); ready <= 1'b0; ref_due <= 1'b0; ref_cnt <= 10'd0;
            chip <= 1'b0; iseq <= 5'd0;
        end else case (st)
            S_INIT: if (tcnt == 0) st <= S_INIT_SEQ; else tcnt <= tcnt - 16'd1;
            // per rank: PRECHARGE ALL, REFRESH, REFRESH, LOAD MODE; 8 cycles apart
            S_INIT_SEQ: begin
                if (tcnt != 0) tcnt <= tcnt - 16'd1;
                else begin
                    chip <= iseq[4];
                    case (iseq[3:0])
                        4'd0: begin cmd <= C_PRE; SDRAM_A <= 13'h0400; end
                        4'd1, 4'd2: cmd <= C_REF;
                        4'd3: begin cmd <= C_MRS; SDRAM_A <= MODE; SDRAM_BA <= 2'b00; end
                        default: ;
                    endcase
                    tcnt <= 16'd8;
                    iseq <= iseq[3:0] == 4'd3 ? {~iseq[4], 4'd0} : iseq + 5'd1;
                    if (iseq == 5'd19) begin st <= S_IDLE; ready <= 1'b1; end
                end
            end

            S_IDLE: begin
                if (ref_due) begin
                    // both ranks, one after the other
                    ref_due <= 1'b0; cmd <= C_REF; chip <= 1'b0; tcnt <= 16'd6; st <= S_REF;
                end else if (ram_req) begin
                    ram_ack <= 1'b1;
                    r_we <= ram_we; r_line <= ram_line; r_addr <= ram_addr; r_be <= ram_be;
                    wn <= 3'd0;
                    if (ram_we) begin st <= S_WCOLL; end
                    else st <= S_ACT;
                end
            end
            S_REF: begin
                if (tcnt != 0) tcnt <= tcnt - 16'd1;
                else if (!chip) begin cmd <= C_REF; chip <= 1'b1; tcnt <= 16'd6; end
                else st <= S_IDLE;
            end

            // writes: take the beats first (one per ram_wready)
            S_WCOLL: begin
                if (ram_wready) begin
                    wbuf[wn[1:0]] <= ram_wdata;
                    wn <= wn + 3'd1;
                end
                if (wn + (ram_wready ? 3'd1 : 3'd0) == (r_line ? 3'd4 : 3'd1)) st <= S_ACT;
                else ram_wready <= !ram_wready || wn + 3'd1 < (r_line ? 3'd4 : 3'd1);
            end

            S_ACT: begin
                cmd <= C_ACT; chip <= r_addr[26]; SDRAM_BA <= r_addr[24:23]; SDRAM_A <= r_addr[22:10];
                rw <= 5'd0; cw <= 2'd0;
                crit <= r_we ? 2'd0 : c0;
                st <= S_RW;
            end
            // the first burst's command at rw = 1, the second's (lines) at
            // rw = 9; a command set at rw = n is on the pins while rw = n + 1
            S_RW: begin
                rw <= rw + 5'd1;
                if (rw == 5'd1 || (rw == 5'd9 && r_line)) begin
                    logic [1:0] d;
                    logic       last;
                    if (r_we) d = r_line ? (rw == 5'd1 ? 2'd0 : 2'd2) : c0;
                    else      d = (rw == 5'd1) ? c0 : c0 ^ 2'b10;
                    last = !r_line || rw == 5'd9;
                    cmd <= r_we ? C_WR : C_RD; SDRAM_A <= col_of(d, last);
                end
                // write data: a burst's 8 words start with its WRITE
                if (r_we && rw >= 5'd1 && rw < (r_line ? 5'd17 : 5'd9)) begin
                    logic [3:0] k;            // word of the line (single: of the burst)
                    k = 4'(rw - 5'd1);
                    dq_oe  <= 1'b1;
                    dq_out <= word_of(wbuf[r_line ? k[3:2] : 2'd0], k[1:0]);
                    if (r_line)               dqm <= 2'b00;
                    else if (k[3:2] == 2'd0)  dqm <= {!r_be[7 - 2*k[1:0]], !r_be[6 - 2*k[1:0]]};
                    else                      dqm <= 2'b11;   // the burst's other doubleword
                end
                // read capture: word k of the bursts is in dq_cap while rw = rd_first + k
                if (!r_we && rw >= rd_first) begin
                    logic [4:0] k;
                    k = rw - rd_first;
                    if (k < (r_line ? 5'd16 : 5'd4)) begin
                        if (cw == 2'd3) begin
                            ram_rvalid <= 1'b1;
                            ram_rdata  <= {asm_w, dq_cap};
                            ram_rbeat  <= crit ^ {k[3], k[2]};    // burst 0: c, c^1; burst 1: c^2, c^3
                        end else asm_w[47 - 16*cw -: 16] <= dq_cap;
                        cw <= cw + 2'd1;
                    end
                end
                // done after the last write word, or once the last burst has
                // left the bus (a single read waits out its unused 4 words)
                if (r_we ? rw == (r_line ? 5'd16 : 5'd8) : rw == 5'(2 + RD_LAT) + (r_line ? 5'd15 : 5'd7)) begin
                    st <= S_WAIT; tcnt <= r_we ? 16'd4 : 16'd2;   // tWR + tRP after a write, tRP after a read
                end
            end
            S_WAIT: if (tcnt != 0) tcnt <= tcnt - 16'd1; else st <= S_IDLE;
            default: st <= S_IDLE;
        endcase
    end
endmodule
