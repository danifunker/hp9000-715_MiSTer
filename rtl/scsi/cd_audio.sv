// The CD-ROM's audio player (rtl/scsi/scsi_targets.sv drives it; STUBS
// S-026): what an XM-3301's PLAY AUDIO commands do, on the image the
// MiSTer serves. Main_MiSTer (support/hp9k, using support/sun/sun_cdrom)
// answers two windows above the data on the CD slot:
//   block 0xC0000000, 2 blocks: the track table -- byte 0 first track, 1
//     the number of tracks n, then from byte 8 n + 1 entries of 8 bytes
//     {ADR/control, track, M, S, F (absolute, 150 frames ahead of LBA 0),
//     LBA[23:0]}, the lead-out (track 0xAA) last;
//   block 0x80000000 + 5f: disc frame f, 2352 bytes of 44.1 kHz 16-bit
//     stereo samples (little-endian, left first) then 208 zero bytes.
// The engine copies the table into toc (port A) and READ
// TOC reads it back there. The player fetches a frame at a time into one of
// two banks (fr_*: the engine's sd port, a 5-block transfer whose halfwords
// arrive on fb_*),
// plays its 588 samples at 44.1 kHz while the other bank fills, and keeps
// the sub-channel position (track, absolute and track-relative M:S:F and
// LBA). Output: the samples times MODE page 0x0E's port 0/1 volume (0-255),
// held between samples, zero unless playing. Frame numbers are 19 bits
// (524,288 frames = 116:30, past the 99:59:74 a disc can hold); the engine
// gives a play address beyond that as the last one (frame19).
module cd_audio #(
    parameter int CLK_HZ = 64_000_000
) (
    input  logic        clk,
    input  logic        rst,
    // the track table: port A (written while copying, read for READ TOC)
    input  logic        toc_we,
    input  logic [6:0]  toc_a,
    input  logic [63:0] toc_wd,
    output logic [63:0] toc_q,              // entry toc_a, a clock later
    input  logic [7:0]  toc_first,          // first track, number of tracks
    input  logic [7:0]  toc_n,
    // commands (pulses): play [p_start, p_end) (absolute LBAs), pause, resume, stop
    input  logic        play,
    input  logic [18:0] p_start, p_end,
    input  logic        pause, resume, stop,
    // READ SUB-CHANNEL: audio status (0x11 playing, 0x12 paused, 0x13
    // completed, 0x15 none) and the position
    output logic [7:0]  a_status,
    input  logic        status_read,        // reported: 0x13 becomes 0x15
    output logic [7:0]  q_ctl, q_track,
    output logic [23:0] q_abs_lba, q_rel_lba,  // q_abs_lba = cur
    output logic [23:0] q_abs_msf, q_rel_msf,  // {M, S, F}
    // frame fetch
    output logic        fr_req,             // held until fr_go
    output logic [31:0] fr_lba,             // 0x80000000 + 5 * frame
    input  logic        fr_go,              // the engine started it
    input  logic        fr_done,            // ... and it finished
    input  logic        fb_we,
    input  logic [10:0] fb_addr,            // halfword in the transfer
    input  logic [15:0] fb_data,
    // volume (MODE page 0x0E)
    input  logic [7:0]  vol_l, vol_r,
    output logic signed [15:0] out_l, out_r
);
    // ------------------------------------------------------------ the track table
    // whole-entry writes: byte-enabled writes with the second read port
    // (tb_q) crash Quartus 17's RAM inference (2026-10-18)
    logic [63:0] toc [128];
    logic [6:0]  tb_a;
    logic [63:0] tb_q;
    always_ff @(posedge clk) begin
        if (toc_we) toc[toc_a] <= toc_wd;
        toc_q <= toc[toc_a];
    end
    always_ff @(posedge clk) tb_q <= toc[tb_a];

    // ------------------------------------------------------------ the frame banks
    // bank b, halfword h at {b, h[10:0]}; a frame's 588 samples are halfwords 0..1175
    logic [15:0] fbuf [4096];
    logic        fill_bank;
    logic [11:0] rd_a;
    logic [15:0] rd_q;
    always_ff @(posedge clk) begin
        if (fb_we) fbuf[{fill_bank, fb_addr}] <= fb_data;
        rd_q <= fbuf[rd_a];
    end

    // ------------------------------------------------------------ the player
    localparam logic [31:0] STEP = 32'((64'd44100 << 32) / CLK_HZ);
    typedef enum logic [1:0] { P_IDLE, P_FIND, P_SCAN, P_PLAY } pst_e;
    pst_e        pst;
    logic        paused;
    logic [18:0] cur, last;                 // the frame playing, the end (exclusive)
    logic [18:0] next_start;                // where the next track starts
    logic [18:0] rel;                       // cur from the track's start
    logic [1:0]  bank_v;                    // the bank holds bank_f
    logic [18:0] bank_f [2];
    logic        pbank;                     // the bank playing
    logic [9:0]  k;                         // sample in the frame
    logic [32:0] acc;
    logic        tick, rd_l, rd_r, rd_r2;
    logic signed [15:0] s_l, s_r;
    logic        fetching;
    logic [7:0]  scan_i;                    // entry in tb_q (+ 1)

    // M:S:F one frame on
    function automatic logic [23:0] msf_inc(input logic [23:0] m);
        logic [7:0] mm, ss, ff;
        {mm, ss, ff} = m;
        if (ff == 8'd74) begin
            ff = 8'd0;
            if (ss == 8'd59) begin ss = 8'd0; mm = mm + 8'd1; end else ss = ss + 8'd1;
        end else ff = ff + 8'd1;
        return {mm, ss, ff};
    endfunction
    // frames to M:S:F by subtraction (at most 74 + 59 clocks), absolute and relative
    logic [19:0] ca_x;                      // cur + 150
    logic [18:0] cr_x;
    logic [7:0]  ca_m, ca_s, cr_m, cr_s;
    logic        ca_go, cr_go;

    // the next frame wanted: the one after cur in the other bank once cur is in its bank
    wire        cur_in = bank_v[pbank] && bank_f[pbank] == cur;
    wire [19:0] want_f = cur_in ? {1'b0, cur} + 20'd1 : {1'b0, cur};
    wire        want_b = cur_in ? ~pbank : pbank;
    wire        need   = pst == P_PLAY && !paused && want_f < {1'b0, last} &&
                         !(bank_v[want_b] && bank_f[want_b] == want_f[18:0]);
    assign q_abs_lba = {5'd0, cur};
    assign q_rel_lba = {5'd0, rel};

    always_ff @(posedge clk) begin
        tick <= 1'b0; rd_l <= 1'b0; rd_r <= rd_l; rd_r2 <= rd_r;
        if (rst) begin
            pst <= P_IDLE; paused <= 1'b0; a_status <= 8'h15;
            bank_v <= 2'b00; fr_req <= 1'b0; fetching <= 1'b0; acc <= 33'd0;
            s_l <= 16'sd0; s_r <= 16'sd0; q_track <= 8'd0; q_ctl <= 8'h10;
            cur <= 19'd0; rel <= 19'd0; q_abs_msf <= 24'h000200; q_rel_msf <= 24'd0;
            ca_go <= 1'b0; cr_go <= 1'b0;
        end else begin
            if (status_read && a_status == 8'h13) a_status <= 8'h15;

            // the sample clock
            acc <= {1'b0, acc[31:0]} + {1'b0, STEP};
            if (acc[32]) tick <= 1'b1;

            // frame transfers
            if (fr_go) begin fr_req <= 1'b0; fetching <= 1'b1; end
            if (fetching && fr_done) begin fetching <= 1'b0; bank_v[fill_bank] <= 1'b1; end
            if (!fr_req && !fetching && need) begin
                // 5 * want_f < 2^22
                fr_req <= 1'b1; fr_lba <= {10'b10_0000_0000, {1'b0, want_f[18:0], 2'b00} + {3'd0, want_f[18:0]}};
                fill_bank <= want_b; bank_f[want_b] <= want_f[18:0]; bank_v[want_b] <= 1'b0;
            end

            // the conversions
            if (ca_go) begin
                if (ca_x >= 20'd4500) begin ca_x <= ca_x - 20'd4500; ca_m <= ca_m + 8'd1; end
                else if (ca_x >= 20'd75) begin ca_x <= ca_x - 20'd75; ca_s <= ca_s + 8'd1; end
                else begin q_abs_msf <= {ca_m, ca_s, ca_x[7:0]}; ca_go <= 1'b0; end
            end
            if (cr_go) begin
                if (cr_x >= 19'd4500) begin cr_x <= cr_x - 19'd4500; cr_m <= cr_m + 8'd1; end
                else if (cr_x >= 19'd75) begin cr_x <= cr_x - 19'd75; cr_s <= cr_s + 8'd1; end
                else begin q_rel_msf <= {cr_m, cr_s, cr_x[7:0]}; cr_go <= 1'b0; end
            end

            case (pst)
                P_IDLE: ;
                // the track holding cur: the last entry (not the lead-out) starting at or before it
                P_FIND: begin
                    tb_a <= 7'd0; scan_i <= 8'd0; pst <= P_SCAN;
                    q_track <= toc_first; q_ctl <= 8'h10; next_start <= last;
                end
                P_SCAN: begin
                    tb_a <= tb_a + 7'd1; scan_i <= scan_i + 8'd1;
                    // (the table's 24-bit LBAs compared whole; one at or before cur, or
                    // before last, fits 19 bits)
                    if (scan_i != 8'd0) begin                       // tb_q = entry scan_i - 1
                        if (scan_i > toc_n || tb_q[23:0] > {5'd0, cur}) begin
                            if (scan_i <= toc_n + 8'd1 && tb_q[23:0] > {5'd0, cur} && tb_q[23:0] < {5'd0, last})
                                next_start <= tb_q[18:0];
                            pst <= P_PLAY;
                        end else begin
                            q_track <= tb_q[55:48]; q_ctl <= tb_q[63:56];
                            rel <= cur - tb_q[18:0];
                            cr_x <= cur - tb_q[18:0]; cr_m <= 8'd0; cr_s <= 8'd0; cr_go <= 1'b1;
                        end
                    end
                end
                P_PLAY: if (tick && !paused && cur == last) begin
                    pst <= P_IDLE; a_status <= 8'h13;                   // the sample after the last one
                end else if (tick && !paused && cur_in) begin
                    // the next sample: halfwords 2k (left) and 2k + 1 (right)
                    rd_a <= {pbank, k, 1'b0}; rd_l <= 1'b1;
                    if (k == 10'd587) begin
                        k <= 10'd0; bank_v[pbank] <= 1'b0; pbank <= ~pbank;
                        cur <= cur + 19'd1;                             // < last: no wrap
                        q_abs_msf <= msf_inc(q_abs_msf);
                        rel <= rel + 19'd1; q_rel_msf <= msf_inc(q_rel_msf);
                        if (cur + 19'd1 != last && cur + 19'd1 == next_start) pst <= P_FIND;   // the next track
                    end else k <= k + 10'd1;
                end
                default: pst <= P_IDLE;
            endcase
            // the sample's two halfwords
            if (rd_l) rd_a <= rd_a + 12'd1;
            if (rd_r) s_l <= $signed(rd_q);
            if (rd_r2) s_r <= $signed(rd_q);

            // commands
            if (stop) begin pst <= P_IDLE; paused <= 1'b0; a_status <= 8'h15; s_l <= 16'sd0; s_r <= 16'sd0; end
            if (pause && pst != P_IDLE) begin paused <= 1'b1; a_status <= 8'h12; end
            if (resume && pst != P_IDLE && paused) begin paused <= 1'b0; a_status <= 8'h11; end
            if (play) begin
                cur <= p_start; last <= p_end; k <= 10'd0; pbank <= 1'b0; bank_v <= 2'b00;
                s_l <= 16'sd0; s_r <= 16'sd0;
                paused <= 1'b0;
                a_status <= p_end > p_start ? 8'h11 : 8'h13;
                pst <= p_end > p_start ? P_FIND : P_IDLE;
                rel <= 19'd0; q_rel_msf <= 24'd0;
                ca_x <= {1'b0, p_start} + 20'd150; ca_m <= 8'd0; ca_s <= 8'd0; ca_go <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------ the output
    wire on = pst == P_PLAY && !paused;
    always_ff @(posedge clk) begin
        logic signed [25:0] l, r;
        l = s_l * $signed({2'b00, vol_l} + {9'd0, vol_l[7]});       // 0..256 (255 = unity)
        r = s_r * $signed({2'b00, vol_r} + {9'd0, vol_r[7]});
        out_l <= on ? l[23:8] : 16'sd0;
        out_r <= on ? r[23:8] : 16'sd0;
    end
endmodule
