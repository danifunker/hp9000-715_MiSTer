// Artist's display (docs/design/artist.md 4): the picture the MiSTer scaler
// takes as the core's video, made the way the 715's RAMDAC makes it -- every
// pixel looked up in LUT0 or LUT1 by its attribute bit, the hardware cursor
// laid over it -- on the machine's clock, one pixel a clock (64 MHz: 1280 x
// 1024 at 44.7 Hz, 1024 x 768 at 72.9 Hz into the scaler; STUBS S-024).
//
// The active size is Artist's (hactive x vactive from its timing registers),
// the blanking fixed: 16 + 32 + 48 clocks a line, 3 + 4 + 9 lines a frame.
// While line n is shown, line n + 1's VRAM words (hactive / 8) and attribute
// words (hactive / 64) are fetched from DDR3 into the other half of two line
// buffers (rf_*: bursts of up to 64 words, one at a time; the request is held
// until rf_ack, then rf_len beats of rf_rvalid). The attribute plane is one
// bit a pixel: word {y, x[10:6]}, pixel x in bit x[5:0]; VRAM pixel x is byte
// lane x[2:0] of word {y, x[10:3]}.
module artist_video (
    input  logic        clk,
    input  logic        rst,
    input  logic [11:0] hactive, vactive,
    input  logic        video_on,
    // the colour maps: LUT0 = entries 0-255, LUT1 = 256-511 (0x00RRGGBB)
    input  logic        lut_wr,
    input  logic [8:0]  lut_addr,
    input  logic [23:0] lut_rgb,
    // the cursor: sprite column 0 at screen x c_x; screen row c_y shows sprite
    // row c_yoff (rows above c_y are not shown); mask 0 = transparent, else
    // image ? c_fg : c_bg. The sprite row c_row arrives on c_img/c_msk one
    // clock later (bit 63 = column 0)
    input  logic        c_on,
    input  logic signed [15:0] c_x, c_y,
    input  logic [5:0]  c_yoff,
    input  logic [23:0] c_fg, c_bg,
    output logic [5:0]  c_row,
    input  logic [63:0] c_img, c_msk,
    // line fetch (DDR3 words: [18] = the attribute plane)
    output logic        rf_req,
    output logic [18:0] rf_addr,
    output logic [6:0]  rf_len,
    input  logic        rf_ack,
    input  logic        rf_rvalid,
    input  logic [63:0] rf_rdata,
    // video
    output logic [7:0]  r, g, b,
    output logic        hs, vs, de,
    output logic        underrun        // a line was shown before its fetch finished (sticky)
);
    localparam logic [11:0] HFP = 12'd16, HSW = 12'd32, HBP = 12'd48;
    localparam logic [10:0] VFP = 11'd3, VSW = 11'd4, VBP = 11'd9;

    // ------------------------------------------------------------ timing
    // the size is taken at the start of a frame (2048 x 1024 at most)
    logic [11:0] ha, hc, ht;
    logic [10:0] va, vc, vt;
    wire         h_last = hc == ht - 12'd1;
    wire         v_last = vc == vt - 11'd1;
    always_ff @(posedge clk) begin
        if (rst) begin
            hc <= 12'd0; vc <= 11'd0; ha <= 12'd640; va <= 11'd480; ht <= 12'd736; vt <= 11'd496;
        end else if (h_last) begin
            hc <= 12'd0;
            if (v_last) begin
                logic [11:0] w;
                logic [10:0] h;
                vc <= 11'd0;
                w = hactive == 12'd0 ? 12'd640 : hactive > 12'd2048 ? 12'd2048 : hactive;
                h = vactive == 12'd0 ? 11'd480 : vactive > 12'd1024 ? 11'd1024 : vactive[10:0];
                ha <= w; va <= h;
                ht <= w + HFP + HSW + HBP; vt <= h + VFP + VSW + VBP;
            end else vc <= vc + 11'd1;
        end else hc <= hc + 12'd1;
    end

    // ------------------------------------------------------------ line buffers
    logic [63:0] vbuf [512];               // {bank, word}
    logic [63:0] abuf [64];                // {bank, word}
    logic [63:0] vq, aq;
    logic        lb_we, lb_attr;
    logic [8:0]  lb_wa;
    logic [63:0] lb_wd;
    always_ff @(posedge clk) begin
        if (lb_we && !lb_attr) vbuf[lb_wa] <= lb_wd;
        vq <= vbuf[{vc[0], hc[10:3]}];
    end
    always_ff @(posedge clk) begin
        if (lb_we && lb_attr) abuf[lb_wa[5:0]] <= lb_wd;
        aq <= abuf[{vc[0], hc[10:6]}];
    end

    // ------------------------------------------------------------ fetch
    // line n is fetched while line n - 1 is shown (line 0 during the last
    // blank line), into bank n[0]
    typedef enum logic [1:0] { F_IDLE, F_VRAM, F_ATTR } fst_e;
    fst_e        f_st;
    logic        f_pend;
    logic [9:0]  f_line, p_line;
    logic [8:0]  f_req, f_got, f_nw;
    logic [5:0]  f_na;
    wire  [10:0] next_line = v_last ? 11'd0 : vc + 11'd1;                 // the line shown after this one
    wire  [10:0] fetch_line = next_line == vt - 11'd1 ? 11'd0 : next_line + 11'd1;
    always_ff @(posedge clk) begin
        lb_we <= 1'b0;
        if (rst) begin
            f_st <= F_IDLE; f_pend <= 1'b0; rf_req <= 1'b0; underrun <= 1'b0;
        end else begin
            if (h_last) begin
                // the line about to be shown must be all there
                if (next_line < va && (f_st != F_IDLE || f_pend)) underrun <= 1'b1;
                if (fetch_line < va) begin f_pend <= 1'b1; p_line <= fetch_line[9:0]; end
            end
            case (f_st)
            F_IDLE: if (f_pend) begin
                f_pend <= 1'b0; f_line <= p_line;
                f_nw <= 9'((ha + 12'd7) >> 3); f_na <= 6'((ha + 12'd63) >> 6);
                f_req <= 9'd0; f_got <= 9'd0;
                f_st <= F_VRAM;
            end
            F_VRAM: begin
                if (!rf_req && f_req < f_nw && f_got == f_req) begin
                    rf_req <= 1'b1;
                    rf_addr <= {1'b0, f_line, f_req[7:0]};
                    rf_len <= f_nw - f_req > 9'd64 ? 7'd64 : 7'(f_nw - f_req);
                end
                if (rf_req && rf_ack) begin rf_req <= 1'b0; f_req <= f_req + 9'(rf_len); end
                if (rf_rvalid) begin
                    lb_we <= 1'b1; lb_attr <= 1'b0; lb_wa <= {f_line[0], f_got[7:0]}; lb_wd <= rf_rdata;
                    f_got <= f_got + 9'd1;
                    if (f_got + 9'd1 == f_nw && f_req == f_nw) begin f_req <= 9'd0; f_got <= 9'd0; f_st <= F_ATTR; end
                end
            end
            F_ATTR: begin
                if (!rf_req && f_req == 9'd0) begin
                    rf_req <= 1'b1;
                    rf_addr <= {1'b1, 3'd0, f_line, 5'd0};
                    rf_len <= {1'b0, f_na};
                end
                if (rf_req && rf_ack) begin rf_req <= 1'b0; f_req <= {3'd0, f_na}; end
                if (rf_rvalid) begin
                    lb_we <= 1'b1; lb_attr <= 1'b1; lb_wa <= {3'd0, f_line[0], f_got[4:0]}; lb_wd <= rf_rdata;
                    f_got <= f_got + 9'd1;
                    if (f_got + 9'd1 == {3'd0, f_na}) f_st <= F_IDLE;
                end
            end
            default: f_st <= F_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------ the cursor's row
    // chosen at the end of a line's active part for the next line, taken at the line change
    logic [63:0] ln_img, ln_msk, nx_img, nx_msk;
    logic        ln_ok, nx_ok, nx_rd, nx_rd2;
    always_ff @(posedge clk) begin
        logic signed [15:0] y, rr;
        nx_rd <= 1'b0; nx_rd2 <= nx_rd;
        y = $signed({5'd0, next_line});
        rr = y - c_y + $signed({10'd0, c_yoff});
        if (hc == ha) begin
            c_row <= rr[5:0];
            nx_ok <= c_on && y >= c_y && rr >= 16'sd0 && rr < 16'sd64;
            nx_rd <= 1'b1;
        end
        // c_row is out a clock after hc == ha, its row a clock after that
        if (nx_rd2) begin nx_img <= c_img; nx_msk <= c_msk; end
        if (h_last) begin ln_img <= nx_img; ln_msk <= nx_msk; ln_ok <= nx_ok; end
    end

    // ------------------------------------------------------------ pixels
    // s0 counters, line-buffer reads -> s1 the pixel, its attribute, LUT read,
    // cursor bits -> s2 the colour -> outputs
    logic [23:0] lut [512];
    logic [23:0] lut_q;
    logic [8:0]  lut_ra;
    always_ff @(posedge clk) begin
        if (lut_wr) lut[lut_addr] <= lut_rgb;
        lut_q <= lut[lut_ra];
    end

    logic [11:0] hc1;
    logic signed [15:0] cx1;
    logic        de1, hs1, vs1, de2, hs2, vs2, c2, ci2;
    always_comb lut_ra = {aq[hc1[5:0]], vq[8 * hc1[2:0] +: 8]};
    always_ff @(posedge clk) begin
        logic de0, hs0, vs0;
        de0 = hc < ha && vc < va;
        hs0 = hc >= ha + HFP && hc < ha + HFP + HSW;
        vs0 = vc >= va + VFP && vc < va + VFP + VSW;
        // s1
        hc1 <= hc; de1 <= de0; hs1 <= hs0; vs1 <= vs0;
        cx1 <= $signed({4'd0, hc}) - c_x;
        // s2
        de2 <= de1; hs2 <= hs1; vs2 <= vs1;
        c2 <= ln_ok && cx1 >= 16'sd0 && cx1 < 16'sd64 && ln_msk[6'd63 - cx1[5:0]];
        ci2 <= ln_img[6'd63 - cx1[5:0]];
        // out
        de <= de2; hs <= hs2; vs <= vs2;
        {r, g, b} <= !de2 || !video_on ? 24'd0 : c2 ? (ci2 ? c_fg : c_bg) : lut_q;
    end
endmodule
