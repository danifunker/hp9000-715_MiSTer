// Artist's display (docs/design/artist.md 4): the picture the MiSTer scaler
// and the analog output take as the core's video, made the way the 715's
// RAMDAC makes it -- every pixel looked up in LUT0 or LUT1 by its attribute
// bit, the hardware cursor laid over it -- at the timing the firmware
// programs (0x300200/0x300208/MISC_VIDEO: active size and porches) on the
// pixel clock `pclk`, which the top makes at the mode's frequency (STUBS
// S-024; artist.sv pix_mode).
//
// Two clocks:
//   clk   the machine's: the line fetch from DDR3 (rf_*), the cursor's rows,
//         LUT writes;
//   pclk  the pixel clock: the raster, the line-buffer and LUT reads, the
//         cursor overlay, the outputs. `prst` holds it (black, counters in
//         the vertical blank) while the clock is retargeted.
// The pixel side announces every line it starts (a toggle with the line's
// numbers, stable for the whole line); the machine side then fetches the
// line two ahead -- its VRAM words (hactive / 8) and attribute words
// (hactive / 64) -- into one of four banks of two line buffers (bank =
// line[1:0]; rf_*: bursts of up to 64 words, one at a time, the request
// held until rf_ack, then rf_len beats of rf_rvalid) and gets the next
// line's cursor row ready (nx_*), which the pixel side takes when that line
// starts. The attribute plane is one bit a pixel: word {y, x[10:6]}, pixel x
// in bit x[5:0]; VRAM pixel x is byte lane x[2:0] of word {y, x[10:3]}.
// Everything that crosses is either a dual-clock RAM, a toggle with data
// held for a line, or a quasi-static value taken through two flops when it
// has been stable (the timing, at the start of a frame).
module artist_video (
    input  logic        clk,
    input  logic        rst,
    input  logic        pclk,
    input  logic        prst,
    // the timing (clk; quasi-static): active size, porches and sync widths
    // in pixels / lines
    input  logic [11:0] hactive, vactive,
    input  logic [10:0] hfp, hsw, hbp,
    input  logic [8:0]  vfp, vsw, vbp,
    input  logic        video_on,
    // the colour maps: LUT0 = entries 0-255, LUT1 = 256-511 (0x00RRGGBB)
    input  logic        lut_wr,
    input  logic [8:0]  lut_addr,
    input  logic [23:0] lut_rgb,
    // the cursor (clk): sprite column 0 at screen x c_x; screen row c_y shows
    // sprite row c_yoff (rows above c_y are not shown); mask 0 = transparent,
    // else image ? c_fg : c_bg. The sprite row c_row arrives on c_img/c_msk
    // one clock later (bit 63 = column 0)
    input  logic        c_on,
    input  logic signed [15:0] c_x, c_y,
    input  logic [5:0]  c_yoff,
    input  logic [23:0] c_fg, c_bg,
    output logic [5:0]  c_row,
    input  logic [63:0] c_img, c_msk,
    // line fetch (clk; DDR3 words: [18] = the attribute plane)
    output logic        rf_req,
    output logic [18:0] rf_addr,
    output logic [6:0]  rf_len,
    input  logic        rf_ack,
    input  logic        rf_rvalid,
    input  logic [63:0] rf_rdata,
    // video (pclk)
    output logic [7:0]  r, g, b,
    output logic        hs, vs, de,
    output logic        vblank,         // (clk) the raster is in its vertical blank
    output logic        underrun        // (clk) a line was due before its fetch finished (sticky)
);
    // ============================================================ pixel side
    // ------------------------------------------------------------ timing
    // taken at the start of a frame when it has been stable for two clocks;
    // an implausible one (before the firmware sets a mode) shows as the
    // ROM's 1280 x 1024 at 60 Hz (monitor 5: 1708 x 1056)
    localparam int TW = 12 + 12 + 3 * 11 + 3 * 9 + 1;
    wire  [TW-1:0] tim_in = {video_on, hactive, vactive, hfp, hsw, hbp, vfp, vsw, vbp};
    logic [TW-1:0] tim_s1, tim_s2, tim_s3;
    always_ff @(posedge pclk) begin tim_s1 <= tim_in; tim_s2 <= tim_s1; tim_s3 <= tim_s2; end

    logic        p_on;
    logic [11:0] ha;                     // active pixels (<= 2048)
    logic [10:0] va;                     // active lines (<= 1024)
    logic [12:0] hs0_at, hs1_at, ht;     // sync from hs0_at to hs1_at, total
    logic [10:0] vs0_at, vs1_at, vt;
    logic [12:0] hc, ht_m1;
    logic [10:0] vc, vt_m1;
    wire         h_last = hc == ht_m1;
    wire         v_last = vc == vt_m1;
    wire  [10:0] nx_line = v_last ? 11'd0 : vc + 11'd1;          // the line after this one

    always_ff @(posedge pclk) begin
        if (prst) begin
            // monitor 5's timing, the counters at the start of the vertical blank
            p_on <= 1'b0; ha <= 12'd1280; va <= 11'd1024;
            hs0_at <= 13'd1324; hs1_at <= 13'd1508; ht <= 13'd1708;
            vs0_at <= 11'd1027; vs1_at <= 11'd1030; vt <= 11'd1056;
            hc <= 13'd0; vc <= 11'd1024;
        end else if (h_last) begin
            hc <= 13'd0;
            vc <= nx_line;
            if (v_last && tim_s2 == tim_s3) begin
                logic        on;
                logic [11:0] w, h;
                logic [10:0] fp, sw, bp;
                logic [8:0]  vf, vw, vb;
                {on, w, h, fp, sw, bp, vf, vw, vb} = tim_s3;
                p_on <= on;
                if (w < 12'd256 || h < 12'd200) begin
                    ha <= 12'd1280; va <= 11'd1024;
                    hs0_at <= 13'd1324; hs1_at <= 13'd1508; ht <= 13'd1708;
                    vs0_at <= 11'd1027; vs1_at <= 11'd1030; vt <= 11'd1056;
                end else begin
                    logic [11:0] wc;
                    logic [10:0] hc_;
                    wc = w > 12'd2048 ? 12'd2048 : w;
                    hc_ = h > 12'd1024 ? 11'd1024 : h[10:0];
                    ha <= wc; va <= hc_;
                    hs0_at <= 13'(wc) + 13'(fp);
                    hs1_at <= 13'(wc) + 13'(fp) + 13'(sw);
                    ht     <= 13'(wc) + 13'(fp) + 13'(sw) + 13'(bp);
                    vs0_at <= hc_ + 11'(vf);
                    vs1_at <= hc_ + 11'(vf) + 11'(vw);
                    vt     <= hc_ + 11'(vf) + 11'(vw) + 11'(vb);
                end
            end
        end else hc <= hc + 13'd1;
    end

    // ------------------------------------------------------------ line announcements
    // at the start of every line: the line now shown, the one after it (for
    // the cursor) and the line two ahead to fetch (if it is an active one),
    // with the width it is fetched at. The numbers only change with vc, once
    // a line, so they are worked out in a pipeline during the line (a few
    // clocks after vc changes) and taken at its end
    logic [10:0] a_l1, a_l2, a_l3;
    logic        a_act, a_fv;
    always_ff @(posedge pclk) begin
        ht_m1 <= ht - 13'd1;
        vt_m1 <= vt - 11'd1;
        a_l1 <= vc == vt_m1 ? 11'd0 : vc + 11'd1;                  // the next line
        a_l2 <= a_l1 == vt_m1 ? 11'd0 : a_l1 + 11'd1;              // the one after it
        a_l3 <= a_l2 == vt_m1 ? 11'd0 : a_l2 + 11'd1;              // two ahead: fetched
        a_act <= a_l1 < va;
        a_fv <= a_l3 < va;
    end

    logic        ls_tog;
    logic [10:0] ls_line, ls_next, ls_fetch;
    logic        ls_fvalid, ls_act;
    logic [11:0] ls_ha;
    always_ff @(posedge pclk) begin
        if (prst) ls_tog <= 1'b0;
        else if (h_last) begin
            ls_tog    <= ~ls_tog;
            ls_line   <= a_l1;
            ls_act    <= a_act;
            ls_next   <= a_l2;
            ls_fetch  <= a_l3;
            ls_fvalid <= a_fv;
            ls_ha     <= ha;
        end
    end

    // ============================================================ machine side
    logic [2:0]  ls_sync;
    always_ff @(posedge clk) ls_sync <= {ls_sync[1:0], ls_tog};
    wire         ls_ev = ls_sync[2] ^ ls_sync[1];

    // ------------------------------------------------------------ line buffers
    // written on clk, read on pclk
    logic [63:0] vbuf [1024];              // {bank, word}
    logic [63:0] abuf [128];               // {bank, word}
    logic        lb_we, lb_attr;
    logic [9:0]  lb_wa;
    logic [63:0] lb_wd;
    always_ff @(posedge clk) begin
        if (lb_we && !lb_attr) vbuf[lb_wa] <= lb_wd;
        if (lb_we &&  lb_attr) abuf[lb_wa[6:0]] <= lb_wd;
    end

    // ------------------------------------------------------------ fetch
    typedef enum logic [1:0] { F_IDLE, F_VRAM, F_ATTR } fst_e;
    fst_e        f_st;
    logic        f_pend;
    logic [9:0]  f_line, p_line;
    logic [11:0] p_ha;
    logic [8:0]  f_req, f_got, f_nw;
    logic [5:0]  f_na;
    always_ff @(posedge clk) begin
        lb_we <= 1'b0;
        if (rst) begin
            f_st <= F_IDLE; f_pend <= 1'b0; rf_req <= 1'b0; underrun <= 1'b0; vblank <= 1'b1;
        end else begin
            if (ls_ev) begin
                // the line now shown must be all there
                if (ls_line < 11'd1024 && ((f_st != F_IDLE && {1'b0, f_line} == ls_line) ||
                                           (f_pend && {1'b0, p_line} == ls_line))) underrun <= 1'b1;
                if (ls_fvalid) begin
                    if (f_pend) underrun <= 1'b1;               // two behind: the older one is dropped
                    f_pend <= 1'b1; p_line <= ls_fetch[9:0]; p_ha <= ls_ha;
                end
                vblank <= !ls_act;
            end
            case (f_st)
            F_IDLE: if (f_pend) begin
                f_pend <= 1'b0; f_line <= p_line;
                f_nw <= 9'((p_ha + 12'd7) >> 3); f_na <= 6'((p_ha + 12'd63) >> 6);
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
                    lb_we <= 1'b1; lb_attr <= 1'b0; lb_wa <= {f_line[1:0], f_got[7:0]}; lb_wd <= rf_rdata;
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
                    lb_we <= 1'b1; lb_attr <= 1'b1; lb_wa <= {3'd0, f_line[1:0], f_got[4:0]}; lb_wd <= rf_rdata;
                    f_got <= f_got + 9'd1;
                    if (f_got + 9'd1 == {3'd0, f_na}) f_st <= F_IDLE;
                end
            end
            default: f_st <= F_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------ the cursor's row
    // for the line after the one just started; the pixel side takes it (and
    // the position and colours with it) when that line starts, a line later
    logic [63:0] nx_img, nx_msk;
    logic        nx_ok, nx_rd, nx_rd2;
    logic signed [15:0] nx_x;
    logic [23:0] nx_fg, nx_bg;
    always_ff @(posedge clk) begin
        logic signed [15:0] y, rr;
        nx_rd <= 1'b0; nx_rd2 <= nx_rd;
        y = $signed({5'd0, ls_next});
        rr = y - c_y + $signed({10'd0, c_yoff});
        if (ls_ev) begin
            c_row <= rr[5:0];
            nx_ok <= c_on && y >= c_y && rr >= 16'sd0 && rr < 16'sd64;
            nx_x <= c_x; nx_fg <= c_fg; nx_bg <= c_bg;
            nx_rd <= 1'b1;
        end
        // c_row is out a clock after ls_ev, its row a clock after that
        if (nx_rd2) begin nx_img <= c_img; nx_msk <= c_msk; end
    end

    // ============================================================ pixel side
    // ------------------------------------------------------------ pixels
    // p0 counters, line-buffer reads -> p1 words -> p2 the pixel, its
    // attribute, the cursor bits -> p3 the LUT read -> outputs
    logic [23:0] lut [512];
    logic [23:0] lut_q;
    logic [8:0]  lut_ra;
    always_ff @(posedge clk) if (lut_wr) lut[lut_addr] <= lut_rgb;
    always_ff @(posedge pclk) lut_q <= lut[lut_ra];

    logic [63:0] vq, aq;
    always_ff @(posedge pclk) begin
        vq <= vbuf[{vc[1:0], hc[10:3]}];
        aq <= abuf[{vc[1:0], hc[10:6]}];
    end

    logic [63:0] ln_img, ln_msk;
    logic        ln_ok;
    logic signed [15:0] ln_x;
    logic [23:0] ln_fg, ln_bg;
    always_ff @(posedge pclk) begin
        if (h_last) begin
            ln_img <= nx_img; ln_msk <= nx_msk; ln_ok <= nx_ok;
            ln_x <= nx_x; ln_fg <= nx_fg; ln_bg <= nx_bg;
        end
    end

    logic [2:0]  hc1;
    logic signed [15:0] cx1;
    logic        de1, hs1, vs1, de2, hs2, vs2, de3, hs3, vs3, c2, ci2, c3, ci3;
    logic [7:0]  pix2;
    logic        at2;
    logic [5:0]  a_bit;
    always_comb lut_ra = {at2, pix2};
    always_ff @(posedge pclk) begin
        // p1
        hc1 <= hc[2:0]; a_bit <= hc[5:0];
        de1 <= hc < 13'(ha) && vc < va;
        hs1 <= hc >= hs0_at && hc < hs1_at;
        vs1 <= vc >= vs0_at && vc < vs1_at;
        cx1 <= $signed({3'd0, hc}) - ln_x;
        // p2: the pixel's byte and attribute bit
        de2 <= de1; hs2 <= hs1; vs2 <= vs1;
        pix2 <= vq[8 * hc1 +: 8];
        at2 <= aq[a_bit];
        c2 <= ln_ok && cx1 >= 16'sd0 && cx1 < 16'sd64 && ln_msk[6'd63 - cx1[5:0]];
        ci2 <= ln_img[6'd63 - cx1[5:0]];
        // p3: the LUT read
        de3 <= de2; hs3 <= hs2; vs3 <= vs2; c3 <= c2; ci3 <= ci2;
        // out
        de <= de3; hs <= hs3; vs <= vs3;
        {r, g, b} <= !de3 || !p_on ? 24'd0 : c3 ? (ci3 ? ln_fg : ln_bg) : lut_q;
    end
endmodule
