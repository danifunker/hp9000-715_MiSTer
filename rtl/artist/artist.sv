// Artist, the HP 9000/715's built-in 8-plane graphics (docs/design/artist.md;
// the register-level specification is docs/review/08-artist-registers.md,
// "08" below). Milestone 1: what HP's PDC 1.6 and its STI routines (in the
// system ROM at 0xF0024000) need for the boot console.
//
// The GSC side answers 0xF8000000-0xF9FFFFFF: the HPA page and everything
// outside region 2 (0xF8100000-0xF837FFFF), region 3 (0xF8380000-0xF8380FFF)
// and the frame-buffer window (0xF9000000-0xF9FFFFFF) bus-errors (08 1.1).
//
// VRAM is 2048 x 1024 x 8 bits outside this module, on the vr_* port (DDR3 on
// the board, an array in the simulator): 64-bit words, word {y, x[10:3]},
// pixel x in byte lane x[2:0] (bits 8*x[2:0] +: 8) -- so that the MiSTer
// scaler can show it as an 8-bit indexed frame buffer with a 2048-byte
// stride. Reads: vr_req/vr_we=0/vr_addr/vr_len held until vr_ack, then
// vr_len beats of vr_rvalid. Writes: vr_req/vr_we=1 is raised with beat 0
// valid on vr_wdata/vr_be; vr_ack comes with vr_wready of beat 0, then one
// vr_wready per further beat (vr_wvalid says a beat is ready).
//
// The drawing engine works a row at a time: a row's span [x0, xend) is read
// into a line buffer when the operation needs the destination (plane mask
// not all ones, or a raster op that reads it), a block move first reads the
// source row into a second one, then the destination words are computed and
// written back in bursts with byte enables. Every write -- rectangle fill,
// block move, a CPU store to the frame-buffer window, a BINC data-port
// write -- is such a span; a CPU load from the window reads up to five
// words. One operation at a time; busy (0x300000 / 0x380000 bit 24) while
// it runs, and a GSC access that must not overtake it (engine registers,
// the window, the LUT load) waits for it (08 2.7).
//
// The colour map: CPU or BINC writes to buffer 15 go to a 512-entry staging
// line; a write to 0x300118 copies entries into the LUT, whose first 256
// entries (LUT0) are the display palette (pal_* out). LUT1 is not kept.
module artist (
    input  logic        clk,
    input  logic        rst_n,          // machine reset
    input  logic        chip_rst,       // LASI IORESET bit 8 (RST_ARTIST_L) clear
    input  logic        dbg_trace,      // simulator: print every operation
    // GSC: req is a one-cycle strobe; one ack (rdata, err) later
    input  logic        req, we,
    input  logic [31:0] addr,
    input  logic [3:0]  be,             // be[3] = byte 0 = wdata[31:24]
    input  logic [31:0] wdata,
    output logic        ack, err,
    output logic [31:0] rdata,
    // VRAM
    output logic        vr_req, vr_we,
    output logic [17:0] vr_addr,
    output logic [6:0]  vr_len,         // 1..64
    input  logic        vr_ack,
    output logic        vr_wvalid,
    output logic [63:0] vr_wdata,
    output logic [7:0]  vr_be,
    input  logic        vr_wready,
    input  logic        vr_rvalid,
    input  logic [63:0] vr_rdata,
    // display
    output logic        video_on,       // MISC_VIDEO bits 27 and 25
    output logic [11:0] hactive, vactive,
    output logic        pal_wr,         // LUT0 entry pal_addr := pal_rgb (0xRRGGBB)
    output logic [7:0]  pal_addr,
    output logic [23:0] pal_rgb,
    output logic        busy
);
    // ------------------------------------------------------------ registers
    logic [31:0] dst_ba, src_ba, ctl_plane, fg, bg, pmask, ibo;      // 0x118004-0x11801C
    logic [31:0] binc_src, binc_dst, binc_mask, r4c0, r520, r580;    // BINC block
    logic [10:0] binc_row;                                           // 0x100620's row counter
    logic [31:0] dstxy, lenxy, srcxy, xfer;                          // 0x100800-0x100820
    logic [31:0] cur_pos, cur_ctl, reg19, r204, reg20, misc_video, r238, r23c, pll, misc_ctrl;
    logic [23:0] r300004;                                            // bytes 0x300005-7
    logic        be_en, srst;
    logic [3:0]  srst_cnt;

    // the GSC transaction being served
    typedef enum logic [1:0] { G_IDLE, G_DEC, G_RD, G_GET } gst_e;
    gst_e        g_st;
    logic        g_we;
    logic [31:0] g_addr, g_wdata;
    logic [3:0]  g_be;

    wire rst = !rst_n || chip_rst;

    function automatic logic [31:0] bmerge(input logic [31:0] o, input logic [31:0] d, input logic [3:0] b);
        return {b[3] ? d[31:24] : o[31:24], b[2] ? d[23:16] : o[23:16], b[1] ? d[15:8] : o[15:8], b[0] ? d[7:0] : o[7:0]};
    endfunction

    // active size from MISC_VIDEO and the timing registers, as self_test computes it (08 3.4)
    wire [13:0] hact4 = {({misc_video[3:0], reg19[31:24]} + 12'd1), 2'b00};
    assign hactive  = hact4[11:0];
    assign vactive  = {misc_video[11:8], reg20[31:24]} + 12'd1;
    assign video_on = misc_video[27] && misc_video[25];

    // the self-test's signature analyser: the constant the STI expects for
    // the current width (08 3.7; STUBS S-023)
    function automatic logic [31:0] signature(input logic [11:0] w);
        case (w)
            12'd1280: return 32'hAC4FFDAC;
            12'd1024: return 32'h43A97116;
            12'd800:  return 32'hDDF1D432;
            12'd640:  return 32'hEC9EB928;
            default:  return 32'd0;
        endcase
    endfunction

    // ------------------------------------------------------------ memories
    // 0x100000-0x1000FF: the state block, plain storage (08 1.2.1)
    logic [31:0] st_ram [64];
    logic [31:0] st_q;
    logic        st_we;
    logic [5:0]  st_wa;
    logic [31:0] st_wd;
    always_ff @(posedge clk) begin
        if (st_we) st_ram[st_wa] <= st_wd;
        st_q <= st_ram[g_addr[7:2]];
    end

    // colour-map staging line (buffer 15); LUT0 lives in the display (pal_*)
    logic [23:0] stg_ram [512];
    logic [23:0] stg_q;
    logic        stg_we;
    logic [8:0]  stg_wa, stg_ra;
    logic [23:0] stg_wd;
    always_ff @(posedge clk) begin
        if (stg_we) stg_ram[stg_wa] <= stg_wd;
        stg_q <= stg_ram[stg_ra];
    end

    // line buffers: SB = a block move's source row, DB = the destination row
    logic [63:0] sb_ram [256];
    logic [63:0] db_ram [256];
    logic [63:0] sb_q, db_q;
    logic        lb_we, lb_sel;           // write one of them (0 SB, 1 DB)
    logic [7:0]  lb_wa, sb_ra, db_ra;
    logic [63:0] lb_wd;
    always_ff @(posedge clk) begin
        if (lb_we && !lb_sel) sb_ram[lb_wa] <= lb_wd;
        sb_q <= sb_ram[sb_ra];
    end
    always_ff @(posedge clk) begin
        if (lb_we && lb_sel) db_ram[lb_wa] <= lb_wd;
        db_q <= db_ram[db_ra];
    end

    // ------------------------------------------------- bitmap access words
    // BA = F<<31 | Otc<<27 | Ots<<24 | A<<21 | J<<16 | B<<12 | I (08 2.1)
    function automatic logic [3:0] ba_buf(input logic [31:0] ba); return ba[15:12]; endfunction
    function automatic logic [3:0] ba_otc(input logic [31:0] ba); return ba[30:27]; endfunction
    function automatic logic [2:0] ba_ots(input logic [31:0] ba); return ba[26:24]; endfunction
    // an image buffer (1, 2 and the others): not the cursor bitmaps (6, 7),
    // the attribute planes (13) or the colour-map staging line (15)
    function automatic logic ba_image(input logic [31:0] ba);
        return !(ba[15:12] == 4'd6 || ba[15:12] == 4'd7 || ba[15:12] == 4'd13 || ba[15:12] == 4'd15);
    endfunction
    // a frame-buffer window offset -> pixel {y[10:0], x[10:0]}; A = 3 is byte
    // addressing (2048 bytes a line), the others one word per pixel (08 1.4)
    function automatic logic [21:0] fb_xy(input logic [31:0] ba, input logic [23:0] off);
        return ba[23:21] == 3'd3 ? {1'b0, off[20:11], off[10:2], 2'b00} : {off[23:13], off[12:2]};
    endfunction

    // X11 raster op: out = rop[{~s, ~d}] bit by bit
    function automatic logic [7:0] rop8(input logic [3:0] r, input logic [7:0] s, input logic [7:0] d);
        logic [7:0] o;
        for (int i = 0; i < 8; i++) o[i] = r[{~s[i], ~d[i]}];
        return o;
    endfunction
    function automatic logic rop_reads_dst(input logic [3:0] r);
        return r[0] != r[1] || r[2] != r[3];
    endfunction

    // ------------------------------------------------------------ the engine
    typedef enum logic [1:0] { K_SOLID, K_BITS, K_BYTES, K_MOVE } kind_e;
    typedef enum logic [3:0] { E_IDLE, E_ROW, E_RDS, E_RDD, E_WR, E_NEXT, E_RDG, E_GET, E_LUT } est_e;
    est_e        e_st;
    kind_e       e_kind;
    logic [11:0] e_x0, e_xend, e_sx;      // span [x0, xend), source x
    logic [10:0] e_y, e_sy, e_rows;       // current rows, rows left
    logic        e_up;                    // a block move going bottom-up
    logic        e_mirror;                // a store into the STI state area: do the other copy's row next
    logic [10:0] e_mirror_y;
    logic [31:0] e_pat, e_mask;
    logic [3:0]  e_be;
    logic [7:0]  e_fg, e_bg, e_pm, e_color;
    logic [3:0]  e_rop;
    logic        e_transp, e_maskena, e_expand, e_rmw, e_get32;
    logic [9:0]  e_lut_n, e_lut_i, e_lut_off;
    // per row
    logic [7:0]  r_w0;                    // first destination word
    logic [8:0]  r_nw;                    // destination words (1..256)
    logic [2:0]  r_sh;                    // source byte offset within a word pair
    logic        r_sneg;                  // the source starts further left in its word than the destination
    // VRAM reads
    logic [17:0] rd_base;
    logic [8:0]  rd_n, rd_req, rd_got;
    logic [63:0] rw [5];                  // a CPU read's words
    // the write pipeline: line-buffer read (step wi) -> compute -> FIFO -> bursts
    logic [8:0]  wi;                      // step 0 primes the source pair, step k+1 makes word k
    logic        p1_v, p1_prime;
    logic [12:0] p1_d;                    // (the word's first pixel) - x0, two's complement
    logic [63:0] prev;
    logic [71:0] fifo [8];
    logic [2:0]  f_rp, f_wp;
    logic [3:0]  f_n;
    logic [8:0]  wr_req, wr_sent;
    logic [31:0] get_data;
    wire         e_busy = e_st != E_IDLE;
    assign busy = e_busy;

    assign vr_wvalid = f_n != 4'd0;
    assign vr_wdata  = fifo[f_rp][63:0];
    assign vr_be     = fifo[f_rp][71:64];

    // line-buffer and staging read addresses (registered reads: data next cycle)
    wire [21:0] g_src_xy = fb_xy(src_ba, g_addr[23:0]);
    assign sb_ra  = 8'(wi - {8'd0, r_sneg});
    assign db_ra  = 8'(wi - 9'd1);
    assign stg_ra = e_st == E_LUT ? 9'(e_sx[8:0] + e_lut_i[8:0]) : g_src_xy[8:0];

    // one destination word from the pipeline's stage 1
    logic [63:0] c_word;
    logic [7:0]  c_be;
    always_comb begin
        logic [127:0] pair;
        logic signed [13:0] span;
        c_word = 64'd0; c_be = 8'd0;
        pair = {sb_q, prev};
        span = $signed({2'b00, e_xend - e_x0});
        for (int j = 0; j < 8; j++) begin
            logic signed [13:0] i;
            logic [7:0] v, d;
            logic       en, bit_;
            i = $signed({p1_d[12], p1_d}) + 14'(j);       // the pixel's index in the span
            en = i >= 0 && i < span;
            v = e_color; bit_ = 1'b1;
            case (e_kind)
                K_BITS: begin
                    bit_ = e_pat[5'd31 - i[4:0]];
                    v = bit_ ? e_fg : e_bg;
                    if (e_maskena && !e_mask[5'd31 - i[4:0]]) en = 1'b0;
                end
                K_BYTES: begin
                    v = e_pat[5'd31 - {i[1:0], 3'd0} -: 8];
                    if (!e_be[2'd3 - i[1:0]]) en = 1'b0;
                    if (e_maskena && !e_mask[5'd31 - {3'd0, i[1:0]}]) en = 1'b0;
                end
                K_MOVE: begin
                    v = pair[8 * (j + r_sh) +: 8];
                    if (e_expand) begin bit_ = |(v & e_pm); v = bit_ ? e_fg : e_bg; end
                end
                default: ;
            endcase
            if (!bit_ && e_transp) en = 1'b0;
            d = db_q[8 * j +: 8];
            c_word[8 * j +: 8] = e_rmw ? ((d & ~e_pm) | (rop8(e_rop, v, d) & e_pm)) : rop8(e_rop, v, 8'd0);
            c_be[j] = en;
        end
    end

    // a CPU read's result from the words in rw
    always_comb begin
        logic [319:0] p;
        logic [255:0] q;
        p = {rw[4], rw[3], rw[2], rw[1], rw[0]};
        q = 256'(p >> (8 * e_x0[2:0]));
        get_data = 32'd0;
        if (e_get32)
            for (int i = 0; i < 32; i++) get_data[31 - i] = |(q[8 * i +: 8] & e_pm);
        else
            get_data = {q[7:0], q[15:8], q[23:16], q[31:24]};
    end

    // ------------------------------------------------------------ the GSC side
    wire  [23:0] g_off  = g_addr[23:0];
    wire  [23:0] g_offw = g_addr[23:0] & 24'hFFFFFC;
    wire         g_fb   = g_addr[31:24] == 8'hF9;
    wire         g_reg3 = g_addr[31:12] == 20'hF8380;
    wire         g_reg2 = g_addr[31:24] == 8'hF8 && g_addr[23:20] != 4'h0 && g_addr[23:19] < 5'h07;  // 0x100000-0x37FFFF
    // accesses that must not overtake a running operation
    wire         g_engine = g_fb || (g_reg2 && g_we &&
                    ((g_off >= 24'h100400 && g_off < 24'h101000) || g_off[23:6] == 18'h04600 || g_offw == 24'h300118));

    // register reads (st_q, the state block's word, is valid in G_RD)
    logic [31:0] reg_rdata;
    always_comb begin
        case (g_offw)
            24'h1007C0: reg_rdata = r4c0;
            24'h118000, 24'h118004: reg_rdata = dst_ba;
            24'h118008: reg_rdata = src_ba;
            24'h11800C: reg_rdata = ctl_plane;
            24'h118010: reg_rdata = fg;
            24'h118014: reg_rdata = bg;
            24'h118018: reg_rdata = pmask;
            24'h11801C: reg_rdata = ibo;
            24'h118020: reg_rdata = r580;
            24'h118024: reg_rdata = binc_mask;
            24'h118028: reg_rdata = binc_dst;
            24'h11802C: reg_rdata = binc_src;
            24'h118034: reg_rdata = r520;
            24'h300000: reg_rdata = {7'd0, e_busy, 24'd0};
            24'h300004: reg_rdata = {8'd0, r300004};
            24'h300008: reg_rdata = 32'h10;
            24'h300100: reg_rdata = cur_pos;
            24'h300104: reg_rdata = cur_ctl;
            24'h300200: reg_rdata = reg19;
            24'h300204: reg_rdata = r204;
            24'h300208: reg_rdata = reg20;
            24'h300218: reg_rdata = misc_video;
            24'h300238: reg_rdata = {2'b00, r238[29:0]};
            24'h30023C: reg_rdata = signature(hactive);
            24'h300300: reg_rdata = pll;
            24'h300308: reg_rdata = misc_ctrl;
            24'h380000: reg_rdata = {7'd0, e_busy, 24'd0};
            24'h380004: reg_rdata = 32'h6CC20006 | {6'd0, 1'b0, be_en, 15'd0, srst, 8'd0};
            24'h380008: reg_rdata = 32'h10;
            default:    reg_rdata = g_offw[23:8] == 16'h1000 ? st_q : 32'd0;
        endcase
    end

    always_ff @(posedge clk) begin
        // operations G_DEC launches, set up after the engine's case below
        logic        lp_put, lp_fill, lp_move;
        logic [31:0] lp_d, lp_dxy, lp_wh, lp_sxy;
        logic [21:0] lp_xy;
        logic [3:0]  lp_be;
        lp_put = 1'b0; lp_fill = 1'b0; lp_move = 1'b0;
        lp_d = g_wdata; lp_be = g_be; lp_xy = 22'd0;
        lp_dxy = dstxy; lp_wh = lenxy; lp_sxy = srcxy;

        ack <= 1'b0; err <= 1'b0;
        st_we <= 1'b0; stg_we <= 1'b0; lb_we <= 1'b0; pal_wr <= 1'b0;
        if (srst_cnt != 4'd0) srst_cnt <= srst_cnt - 4'd1;
        srst <= srst_cnt > 4'd1;

        if (rst) begin
            g_st <= G_IDLE; e_st <= E_IDLE;
            dst_ba <= 32'd0; src_ba <= 32'd0; ctl_plane <= 32'd0; fg <= 32'd0; bg <= 32'd0;
            pmask <= 32'd0; ibo <= 32'd0;
            binc_src <= 32'd0; binc_dst <= 32'd0; binc_mask <= 32'd0; binc_row <= 11'd0;
            r4c0 <= 32'd0; r520 <= 32'd0; r580 <= 32'd0;
            dstxy <= 32'd0; lenxy <= 32'd0; srcxy <= 32'd0; xfer <= 32'd0;
            cur_pos <= 32'd0; cur_ctl <= 32'd0; reg19 <= 32'd0; r204 <= 32'd0; reg20 <= 32'd0;
            // MISC_VIDEO's active-size fields come out of reset at 1280 x 1024
            // (bits 11:8 = 3, 3:0 = 1, as in every 1280-wide record), the rest 0:
            // the STI keeps its state at (1536, 384) when bits 3:0 != 0, else at
            // (1536, 776); its cold path writes freq_ref there before the first
            // mode set, and the PDC's next init_graph reads it back from where the
            // 1280 mode puts it -- from 0 it would divide by zero (artist.md 1)
            misc_video <= 32'h0000_0301; r238 <= 32'd0; r23c <= 32'd0; pll <= 32'd0; misc_ctrl <= 32'd0;
            r300004 <= 24'd0; be_en <= 1'b1; srst_cnt <= 4'd0; srst <= 1'b0;
            vr_req <= 1'b0; f_n <= 4'd0; f_rp <= 3'd0; f_wp <= 3'd0; p1_v <= 1'b0;
        end else begin
            // ============================================== GSC transactions
            case (g_st)
            G_IDLE: if (req) begin
                g_we <= we; g_addr <= addr; g_be <= be; g_wdata <= wdata;
                g_st <= G_DEC;
            end
            G_DEC: begin
                if (!(g_fb || g_reg2 || g_reg3)) begin
                    ack <= 1'b1; err <= 1'b1; rdata <= 32'd0; g_st <= G_IDLE;
                end else if (g_engine && e_busy) begin
                    // wait for the running operation
                end else if (g_fb && g_we) begin
                    lp_put = 1'b1; lp_xy = fb_xy(dst_ba, g_off);
                    ack <= 1'b1; g_st <= G_IDLE;
                end else if (g_fb) begin
                    if (ba_buf(src_ba) == 4'd15)
                        g_st <= G_RD;           // the staging entry (stg_ra follows g_addr)
                    else if (!ba_image(src_ba) || g_src_xy[21:11] >= 11'd1024) begin
                        ack <= 1'b1; rdata <= 32'd0; g_st <= G_IDLE;
                    end else begin
                        // read the words under pixels x..x+3 (x..x+31 for a bitmap)
                        logic [11:0] x1;
                        e_get32 <= ba_otc(src_ba) == 4'd5;
                        e_pm <= pmask[7:0];
                        e_x0 <= {1'b0, g_src_xy[10:0]};
                        x1 = {1'b0, g_src_xy[10:0]} + (ba_otc(src_ba) == 4'd5 ? 12'd31 : 12'd3);
                        if (x1 > 12'd2047) x1 = 12'd2047;
                        rd_base <= {g_src_xy[20:11], g_src_xy[10:3]};
                        rd_n <= 9'(x1[10:3] - g_src_xy[10:3]) + 9'd1;
                        rd_req <= 9'd0; rd_got <= 9'd0;
                        for (int k = 0; k < 5; k++) rw[k] <= 64'd0;
                        e_st <= E_RDG;
                        g_st <= G_GET;
                    end
                end else if (!g_we) begin
                    g_st <= G_RD;               // st_q is valid next cycle
                end else begin
                    // ----------------------------------------- register writes
                    case (g_offw)
                        24'h100480: binc_src <= bmerge(binc_src, g_wdata, g_be);
                        24'h1004A0: begin binc_dst <= bmerge(binc_dst, g_wdata, g_be); binc_row <= 11'd0; end
                        24'h1004C0: r4c0 <= bmerge(r4c0, g_wdata, g_be);
                        24'h100520: r520 <= bmerge(r520, g_wdata, g_be);
                        24'h100580: r580 <= bmerge(r580, g_wdata, g_be);
                        24'h1005A0: binc_mask <= bmerge(binc_mask, g_wdata, g_be);
                        24'h1005C0, 24'h100600, 24'h100604, 24'h100620: begin
                            // BINC data: a window write at the BINC address (+ the row counter)
                            lp_put = 1'b1;
                            lp_xy = fb_xy(dst_ba, binc_dst[23:0]);
                            lp_xy[21:11] = lp_xy[21:11] + binc_row;
                            if (g_offw == 24'h100620) binc_row <= binc_row + 11'd1;
                            else if (g_offw != 24'h1005C0)
                                // advance x by the pixels a word carries
                                binc_dst <= binc_dst + (ba_otc(dst_ba) == 4'd5 ? 32'h80 :
                                            ba_buf(dst_ba) == 4'd15 || ba_otc(dst_ba) == 4'd7 ? 32'h4 :
                                            dst_ba[23:21] == 3'd3 ? 32'h4 : 32'h10);
                        end
                        24'h100800: dstxy <= bmerge(dstxy, g_wdata, g_be);
                        24'h100804: lenxy <= bmerge(lenxy, g_wdata, g_be);
                        24'h100808: srcxy <= bmerge(srcxy, g_wdata, g_be);
                        24'h100820: xfer <= bmerge(xfer, g_wdata, g_be);
                        24'h100A00: begin lp_dxy = bmerge(dstxy, g_wdata, g_be); dstxy <= lp_dxy; lp_fill = 1'b1; end
                        24'h100A04: begin lp_wh = bmerge(lenxy, g_wdata, g_be); lenxy <= lp_wh; lp_fill = 1'b1; end
                        24'h100B00: begin lp_dxy = bmerge(dstxy, g_wdata, g_be); dstxy <= lp_dxy; lp_move = 1'b1; end
                        24'h100B04: begin lp_wh = bmerge(lenxy, g_wdata, g_be); lenxy <= lp_wh; lp_move = 1'b1; end
                        24'h118000: begin dst_ba <= bmerge(dst_ba, g_wdata, g_be); src_ba <= bmerge(src_ba, g_wdata, g_be); end
                        24'h118004: dst_ba <= bmerge(dst_ba, g_wdata, g_be);
                        24'h118008: src_ba <= bmerge(src_ba, g_wdata, g_be);
                        24'h11800C: ctl_plane <= bmerge(ctl_plane, g_wdata, g_be);
                        24'h118010: fg <= bmerge(fg, g_wdata, g_be);
                        24'h118014: bg <= bmerge(bg, g_wdata, g_be);
                        24'h118018: pmask <= bmerge(pmask, g_wdata, g_be);
                        24'h11801C: ibo <= bmerge(ibo, g_wdata, g_be);
                        24'h118024: binc_mask <= bmerge(binc_mask, g_wdata, g_be);
                        24'h300004: r300004 <= 24'(bmerge({8'd0, r300004}, g_wdata, g_be));
                        24'h300100: cur_pos <= bmerge(cur_pos, g_wdata, g_be);
                        24'h300104: cur_ctl <= bmerge(cur_ctl, g_wdata, g_be);
                        24'h300118: begin
                            logic [31:0] v;
                            v = bmerge(32'd0, g_wdata, g_be);
                            if (v[31]) begin
                                // LUT load: ctl[9:0] staging entries from the BINC source's x
                                e_sx <= {1'b0, binc_src[12:2]};
                                e_lut_n <= v[9:0] == 10'd0 || v[9:0] > 10'd512 ? 10'd512 : v[9:0];
                                e_lut_off <= v[25:16];
                                e_lut_i <= 10'd0;
                                p1_v <= 1'b0;
                                e_st <= E_LUT;
`ifdef SIMULATION
                                if (dbg_trace) $display("artist: lut  ctl %08x src %08x", v, binc_src);
`endif
                            end
                        end
                        24'h300200: reg19 <= bmerge(reg19, g_wdata, g_be);
                        24'h300204: r204 <= bmerge(r204, g_wdata, g_be);
                        24'h300208: reg20 <= bmerge(reg20, g_wdata, g_be);
                        24'h300218: misc_video <= bmerge(misc_video, g_wdata, g_be);
                        24'h300238: r238 <= bmerge(r238, g_wdata, g_be);
                        24'h30023C: r23c <= bmerge(r23c, g_wdata, g_be);
                        24'h300300: pll <= bmerge(pll, g_wdata, g_be);
                        24'h300308: misc_ctrl <= bmerge(misc_ctrl, g_wdata, g_be);
                        24'h380004: begin
                            // bit 8: reset the engine (self-clearing; clears the
                            // bus-error timer enable, bit 24, which the ROM sets again)
                            if (g_be[1] && g_wdata[8]) begin srst_cnt <= 4'd15; srst <= 1'b1; be_en <= 1'b0; end
                            else if (g_be[3]) be_en <= g_wdata[24];
                        end
                        default:
                            if (g_off[23:8] == 16'h1000) begin
                                st_we <= 1'b1; st_wa <= g_off[7:2]; st_wd <= bmerge(st_q, g_wdata, g_be);
                            end
                    endcase
                    ack <= 1'b1; g_st <= G_IDLE;
                end
            end
            G_RD: begin
                ack <= 1'b1;
                rdata <= g_fb ? {8'd0, stg_q} : reg_rdata;
                g_st <= G_IDLE;
            end
            G_GET: if (e_st == E_IDLE) begin
                ack <= 1'b1; rdata <= get_data; g_st <= G_IDLE;
`ifdef SIMULATION
                if (dbg_trace) $display("artist: get  %0d,%0d ba %08x -> %08x", g_src_xy[10:0], g_src_xy[21:11], src_ba, get_data);
`endif
            end
            default: g_st <= G_IDLE;
            endcase

            // ============================================== the engine
            case (e_st)
            E_ROW: begin
                if (e_rows == 11'd0) e_st <= E_IDLE;
                else begin
                    logic [11:0] xl, sxl;
                    xl  = e_xend - 12'd1;
                    sxl = e_sx + (e_xend - e_x0) - 12'd1;
                    r_w0 <= e_x0[10:3];
                    r_nw <= 9'(xl[10:3] - e_x0[10:3]) + 9'd1;
                    r_sh <= 3'(e_sx[2:0] - e_x0[2:0]);
                    r_sneg <= e_sx[2:0] < e_x0[2:0];
                    rd_req <= 9'd0; rd_got <= 9'd0;
                    wi <= 9'd0; wr_req <= 9'd0; wr_sent <= 9'd0; p1_v <= 1'b0;
                    if (e_kind == K_MOVE) begin
                        rd_base <= {e_sy[9:0], e_sx[10:3]};
                        rd_n <= 9'(sxl[10:3] - e_sx[10:3]) + 9'd1;
                        e_st <= E_RDS;
                    end else if (e_rmw) begin
                        rd_base <= {e_y[9:0], e_x0[10:3]};
                        rd_n <= 9'(xl[10:3] - e_x0[10:3]) + 9'd1;
                        e_st <= E_RDD;
                    end else e_st <= E_WR;
                end
            end
            // a row's words into SB (source) / DB (destination) / rw (a CPU read)
            E_RDS, E_RDD, E_RDG: begin
                logic [8:0] got;
                got = rd_got;
                if (!vr_req && rd_got == rd_req && rd_req < rd_n) begin
                    vr_req <= 1'b1; vr_we <= 1'b0;
                    vr_addr <= rd_base + 18'(rd_req);
                    vr_len <= (rd_n - rd_req) > 9'd64 ? 7'd64 : 7'(rd_n - rd_req);
                end
                if (vr_req && vr_ack) begin vr_req <= 1'b0; rd_req <= rd_req + 9'(vr_len); end
                if (vr_rvalid) begin
                    lb_we <= e_st != E_RDG; lb_sel <= e_st == E_RDD; lb_wa <= rd_got[7:0]; lb_wd <= vr_rdata;
                    if (e_st == E_RDG && rd_got < 9'd5) rw[rd_got[2:0]] <= vr_rdata;
                    got = rd_got + 9'd1;
                    rd_got <= got;
                end
                if (got == rd_n && rd_req == rd_n) begin
                    if (e_st == E_RDG) e_st <= E_GET;
                    else if (e_st == E_RDS && e_rmw) begin
                        rd_base <= {e_y[9:0], e_x0[10:3]};
                        rd_n <= r_nw; rd_req <= 9'd0; rd_got <= 9'd0;
                        e_st <= E_RDD;
                    end else e_st <= E_WR;
                end
            end
            E_GET: e_st <= E_IDLE;              // get_data is ready; G_GET answers
            // compute and write back the destination words
            E_WR: begin
                logic       push, pop;
                logic [8:0] sent;
                push = 1'b0; pop = 1'b0; sent = wr_sent;
                // issue step wi's line-buffer reads while the FIFO has room
                p1_v <= 1'b0;
                if (wi <= r_nw && ({1'b0, f_n} + {4'd0, p1_v}) < 5'd6) begin
                    p1_v <= 1'b1; p1_prime <= wi == 9'd0;
                    p1_d <= 13'({2'b00, r_w0, 3'd0} + {wi - 9'd1, 3'd0}) - 13'(e_x0);
                    wi <= wi + 9'd1;
                end
                // stage 1: the word, into the FIFO
                if (p1_v) begin
                    prev <= sb_q;
                    if (!p1_prime) begin
                        fifo[f_wp] <= {c_be, c_word}; f_wp <= f_wp + 3'd1; push = 1'b1;
                    end
                end
                // bursts of up to 64 beats
                if (!vr_req && wr_sent == wr_req && wr_req < r_nw && f_n != 4'd0) begin
                    vr_req <= 1'b1; vr_we <= 1'b1;
                    vr_addr <= {e_y[9:0], 8'(r_w0 + wr_req[7:0])};
                    vr_len <= (r_nw - wr_req) > 9'd64 ? 7'd64 : 7'(r_nw - wr_req);
                end
                if (vr_req && vr_ack) begin vr_req <= 1'b0; wr_req <= wr_req + 9'(vr_len); end
                if (vr_wready) begin pop = 1'b1; f_rp <= f_rp + 3'd1; sent = wr_sent + 9'd1; wr_sent <= sent; end
                f_n <= f_n + (push ? 4'd1 : 4'd0) - (pop ? 4'd1 : 4'd0);
                if (sent == r_nw) e_st <= E_NEXT;
            end
            E_NEXT: begin
                e_rows <= e_rows - 11'd1;
                e_y  <= e_mirror ? e_mirror_y : e_up ? e_y - 11'd1 : e_y + 11'd1;
                e_sy <= e_up ? e_sy - 11'd1 : e_sy + 11'd1;
                e_st <= E_ROW;
            end
            // the colour map: staging[sx + i] -> LUT[off + i] (stg_ra = sx + i; the entry comes next cycle)
            E_LUT: begin
                p1_v <= e_lut_i < e_lut_n;
                p1_d <= 13'(e_lut_off + e_lut_i);
                if (p1_v && p1_d < 13'd256) begin pal_wr <= 1'b1; pal_addr <= p1_d[7:0]; pal_rgb <= stg_q; end
                if (e_lut_i < e_lut_n) e_lut_i <= e_lut_i + 10'd1;
                else if (!p1_v) e_st <= E_IDLE;
            end
            default: ;
            endcase

            // ============================================== launches (the engine is idle)
            if (lp_put || lp_fill || lp_move) begin
                e_fg <= fg[7:0]; e_bg <= bg[7:0]; e_pm <= pmask[7:0]; e_rop <= ibo[11:8];
                e_transp <= ibo[28] || ibo[1];
                e_maskena <= ibo[29];
                e_mask <= binc_mask;
                e_rmw <= pmask[7:0] != 8'hFF || rop_reads_dst(ibo[11:8]);
                e_up <= 1'b0; e_expand <= 1'b0; e_mirror <= 1'b0;
                e_color <= ibo[1] ? fg[7:0] : bg[7:0];
                e_sx <= 12'd0; e_sy <= 11'd0;
            end
            if (lp_put) begin
                // a window or BINC write through DST_BM_ACCESS at pixel lp_xy
                logic [11:0] n;
                if (ba_buf(dst_ba) == 4'd15) begin
                    // colour-map staging: one entry per word
                    stg_we <= 1'b1; stg_wa <= lp_xy[8:0]; stg_wd <= lp_d[23:0];
`ifdef SIMULATION
                    if (dbg_trace) $display("artist: stage %0d = %06x", lp_xy[10:0], lp_d[23:0]);
`endif
                end else if (ba_image(dst_ba) && lp_xy[21:11] < 11'd1024) begin
                    n = ba_otc(dst_ba) == 4'd5 ? 12'd32 : 12'd4;
                    if ({1'b0, lp_xy[10:0]} + n > 12'd2048) n = 12'd2048 - {1'b0, lp_xy[10:0]};
                    e_x0 <= {1'b0, lp_xy[10:0]};
                    e_xend <= {1'b0, lp_xy[10:0]} + n;
                    e_y <= lp_xy[21:11]; e_rows <= 11'd1;
                    e_pat <= lp_d; e_be <= lp_be;
                    // the STI's private state (STUBS S-023, artist.md 1): a store
                    // in its access mode to x 1536..1679 of row 384 or 776 goes
                    // to both rows, so the copy a mode change moves to is valid
                    if (dst_ba == 32'h1360_2000 && lp_xy[10:0] >= 11'd1536 && lp_xy[10:0] < 11'd1680 &&
                        (lp_xy[21:11] == 11'd384 || lp_xy[21:11] == 11'd776)) begin
                        e_mirror <= 1'b1; e_rows <= 11'd2;
                        e_mirror_y <= lp_xy[21:11] == 11'd384 ? 11'd776 : 11'd384;
                    end
                    if (ba_otc(dst_ba) == 4'd5) begin
                        e_kind <= K_BITS;
                        if (ba_ots(dst_ba) != 3'd6) begin e_fg <= 8'd1; e_bg <= 8'd0; end
                    end else e_kind <= K_BYTES;
                    e_st <= E_ROW;
`ifdef SIMULATION
                    if (dbg_trace) $display("artist: put  %0d,%0d ba %08x d %08x be %x ibo %08x pm %02x fg %02x bg %02x mask %08x",
                                        lp_xy[10:0], lp_xy[21:11], dst_ba, lp_d, lp_be, ibo, pmask[7:0], fg[7:0], bg[7:0], binc_mask);
`endif
                end
            end
            if ((lp_fill || lp_move) && ctl_plane == 32'd0 && ba_image(dst_ba) &&
                lp_dxy[31:16] < 16'd2048 && lp_dxy[15:0] < 16'd1024 && lp_wh[31:16] != 16'd0 && lp_wh[15:0] != 16'd0 &&
                (lp_fill || (lp_sxy[31:16] < 16'd2048 && lp_sxy[15:0] < 16'd1024))) begin
                // rectangle fill / block move at lp_dxy (x<<16 | y), size lp_wh (w<<16 | h), clipped to the VRAM
                logic [16:0] w, h;
                w = {1'b0, lp_wh[31:16]}; h = {1'b0, lp_wh[15:0]};
                if (w > 17'd2048 - {1'b0, lp_dxy[31:16]}) w = 17'd2048 - {1'b0, lp_dxy[31:16]};
                if (h > 17'd1024 - {1'b0, lp_dxy[15:0]}) h = 17'd1024 - {1'b0, lp_dxy[15:0]};
                if (lp_move) begin
                    if (w > 17'd2048 - {1'b0, lp_sxy[31:16]}) w = 17'd2048 - {1'b0, lp_sxy[31:16]};
                    if (h > 17'd1024 - {1'b0, lp_sxy[15:0]}) h = 17'd1024 - {1'b0, lp_sxy[15:0]};
                end
                e_x0 <= lp_dxy[27:16]; e_xend <= lp_dxy[27:16] + w[11:0];
                e_rows <= h[10:0];
                e_y <= lp_dxy[10:0];
                if (lp_fill) e_kind <= K_SOLID;
                else begin
                    e_kind <= K_MOVE;
                    e_expand <= ba_ots(dst_ba) == 3'd6;
                    e_sx <= lp_sxy[27:16];
                    // overlapping rows: copy bottom-up when moving down
                    e_up <= lp_dxy[15:0] > lp_sxy[15:0];
                    e_y  <= lp_dxy[15:0] > lp_sxy[15:0] ? 11'(lp_dxy[15:0] + h[15:0] - 16'd1) : lp_dxy[10:0];
                    e_sy <= lp_dxy[15:0] > lp_sxy[15:0] ? 11'(lp_sxy[15:0] + h[15:0] - 16'd1) : lp_sxy[10:0];
                end
                e_st <= E_ROW;
`ifdef SIMULATION
                if (dbg_trace) $display("artist: %s %0d,%0d -> %0d,%0d %0dx%0d ibo %08x pm %02x fg %02x bg %02x ba %08x/%08x",
                                    lp_fill ? "fill" : "move", lp_sxy[31:16], lp_sxy[15:0], lp_dxy[31:16], lp_dxy[15:0],
                                    w, h, ibo, pmask[7:0], fg[7:0], bg[7:0], src_ba, dst_ba);
`endif
            end
        end
    end
endmodule
