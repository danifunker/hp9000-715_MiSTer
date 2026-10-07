// Instruction caches: the 128 KB direct-mapped L2-I (32-byte lines, the same
// RAM and tag formats as the D-cache) and the 1 KB on-chip L1-I in front of
// it (128 doubleword entries, each {parities, STEER, RPN, QPAGE, 2 words};
// ERS s.4.5, s.8.2.9, s.8.3.7). docs/design/cpu.md 6.5.
//
// Lookup: the fetch unit issues the address of the instruction entering F1
// (lk_en); during F1 both RAMs and the L1 are read and compared against the
// address (real mode: PA = VA), the L1 wins when enabled and matching, and
// the fetch unit registers the word into F2. On an L1 miss with an L2 hit the
// doubleword is copied into the L1 (when DR0.L1ICACHE_EN). `lk_valid` says
// the RAM outputs still belong to the fetch unit's last lookup; the engine
// clears it while it owns the read port and the fetch unit then re-issues.
//
// Engine (one operation at a time): line fills for the fetch unit
// (non-speculative, the fetch unit starts them only when the pipeline has
// drained), FIC/FICE and the diagnose ops RI2D/RI2T/WI2D/WI2T/RI1/WI1 for W.
// Lines planted by WI2D/SET_TAG/WI2T serve fetches by tag match alone (the
// ROM runs code from them with no memory behind, BOOT s.4.5).
module pa_icache
    import pa_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,
    output logic        ready,
    output logic        busy,           // the engine owns the read port
    input  logic        l1_en,          // DR0 L1ICACHE_EN

    // fetch lookup (F1)
    input  logic        lk_en,
    input  logic [31:0] lk_addr,        // VA
    input  logic [4:0]  lk_hash,        // space hash into index bits 16:12
    input  logic [31:0] f1_addr,        // the instruction in F1 (registered lk_addr)
    input  logic [19:0] f1_rpn,         // its RPN (the I-LAB's, or the address in real mode)
    output logic        lk_valid,
    output logic [31:0] f1_word,
    output logic        f1_hit,
    output logic [3:0]  f1_perr,        // {L1 tag, L1 data, L2 tag/dirty, L2 word}
    output logic        f1_l1hit,

    // fetch: line fill
    input  logic        fill_req,
    input  logic [31:0] fill_addr,      // VA
    input  logic [4:0]  fill_hash,
    input  logic [19:0] fill_rpn,
    output logic        fill_done,
    output logic        fill_err,

    // W operations
    input  logic        op_req,
    input  ic_op_e      op,
    input  logic [31:0] op_addr,
    input  logic [4:0]  op_hash,
    input  logic [19:0] op_rpn,
    input  logic [31:0] op_wdata,       // WI2D: GR[x]; WI2T: the SET_TAG latch
    input  logic [31:0] dr27, dr28, dr29,
    output logic        op_done,
    output logic        op_hit,
    output logic [3:0]  op_perr,
    output logic [31:0] op_rdata,
    output logic [31:0] rd_dr27, rd_dr28, rd_dr29,

    // line port
    output logic        ln_req,
    output logic [31:0] ln_addr,
    input  logic        ln_ack,
    input  logic [63:0] ln_rdata,
    input  logic        ln_rvalid,
    input  logic [1:0]  ln_rbeat,
    input  logic        ln_rerr
);
    localparam logic [19:0] RPN_INVALID = 20'hF0000;
    localparam logic [7:0]  STEER_FILL = 8'h62;   // what the ROM writes into empty entries (P-012)

    // ---------------------------------------------------------------- RAMs
    logic [13:0] d_raddr, d_waddr;
    logic [65:0] d_q, d_wdata;
    logic        d_we, ren;
    logic [11:0] t_raddr, t_waddr;
    logic [22:0] t_q, t_wdata;
    logic        t_we;
    logic [6:0]  l1_raddr, l1_waddr;
    logic [95:0] l1_q, l1_wdata;
    logic        l1_we;
    pa_cache_ram #(.WIDTH(66), .DEPTH_LOG2(14)) u_data (
        .clk(clk), .raddr(d_raddr), .ren(ren), .rdata(d_q), .we(d_we), .waddr(d_waddr), .wdata(d_wdata));
    pa_cache_ram #(.WIDTH(23), .DEPTH_LOG2(12)) u_tag (
        .clk(clk), .raddr(t_raddr), .ren(ren), .rdata(t_q), .we(t_we), .waddr(t_waddr), .wdata(t_wdata));
    pa_cache_ram #(.WIDTH(96), .DEPTH_LOG2(7)) u_l1 (
        .clk(clk), .raddr(l1_raddr), .ren(ren), .rdata(l1_q), .we(l1_we), .waddr(l1_waddr), .wdata(l1_wdata));

    function automatic logic par32(input logic [31:0] w); return ^w; endfunction
    function automatic logic [22:0] mk_tag(input logic [19:0] rpn);
        return {rpn, 1'b0, 1'b1, ^rpn};
    endfunction
    // L1 entry: {fpdata, fptag, steer[7:0], rpn[19:0], qpage[1:0], dw[63:0]}
    function automatic logic [95:0] mk_l1(input logic [31:0] tagw, input logic [63:0] dw);
        // tagw in DR29 format; its parity bits flip the computed parity (seeding)
        logic [29:0] t;
        t = tagw[29:0];
        return {^dw ^ tagw[31], ^t ^ tagw[30], t, dw};
    endfunction
    wire [19:0] tq_rpn = t_q[22:3];
    wire        tq_valid = tq_rpn != RPN_INVALID;
    wire [1:0]  tq_perr = {t_q[1] != ~t_q[2], t_q[0] != ^tq_rpn};
    wire [3:0]  q_perr  = {tq_perr, d_q[64] != par32(d_q[31:0]), d_q[65] != par32(d_q[63:32])};
    wire [19:0] l1_rpn = l1_q[85:66];
    wire [1:0]  l1_qpage = l1_q[65:64];
    wire        l1_perr_data = l1_q[95] != ^l1_q[63:0];
    wire        l1_perr_tag  = l1_q[94] != ^l1_q[93:64];

    // ---------------------------------------------------------------- state
    typedef enum logic [3:0] { S_INIT, S_IDLE, S_RD, S_Q, S_FILLREQ, S_FILLDATA, S_FILLTAG, S_INVAL, S_L1INV, S_DONE } st_e;
    st_e         st;
    logic [12:0] init_cnt;
    logic [3:0]  fill_got;
    logic        ferr, cur_fill, last_wi_odd;
    logic [13:0] last_wi_idx;
    logic [1:0]  l1cnt;
    assign ready = st != S_INIT;
    assign busy = st != S_IDLE;
    wire [31:0] e_addr = cur_fill ? fill_addr : op_addr;
    wire [4:0]  e_hash = cur_fill ? fill_hash : op_hash;
    wire [19:0] e_rpn  = cur_fill ? fill_rpn : op_rpn;
    wire [13:0] e_idx  = {e_addr[16:12] ^ e_hash, e_addr[11:3]};
    wire [13:0] lk_idx = {lk_addr[16:12] ^ lk_hash, lk_addr[11:3]};

    // ---------------------------------------------------------------- read port
    always_comb begin
        ren = 1'b1;
        d_raddr = lk_idx; t_raddr = lk_idx[13:2]; l1_raddr = lk_addr[9:3];
        if (busy) begin
            d_raddr = (op == IC_WI2T && !cur_fill) ? last_wi_idx : e_idx;
            t_raddr = e_idx[13:2];
            l1_raddr = e_addr[9:3];
        end else if (!lk_en) ren = 1'b0;
    end
    always_ff @(posedge clk) begin
        if (!rst_n) lk_valid <= 1'b0;
        else if (busy) lk_valid <= 1'b0;
        else if (lk_en) lk_valid <= 1'b1;
    end

    // ---------------------------------------------------------------- F1 results
    wire l2_hit = tq_rpn == f1_rpn;
    wire l1_hit = l1_en && l1_rpn == f1_rpn && l1_qpage == f1_addr[11:10];
    wire [63:0] dw = l1_hit ? l1_q[63:0] : d_q[63:0];
    assign f1_word  = f1_addr[2] ? dw[31:0] : dw[63:32];
    assign f1_hit   = lk_valid && !busy && (l1_hit || l2_hit);
    assign f1_l1hit = l1_hit;
    assign f1_perr  = {l1_hit & l1_perr_tag, l1_hit & l1_perr_data,
                       ~l1_hit & (|tq_perr), ~l1_hit & (f1_addr[2] ? d_q[64] != par32(d_q[31:0]) : d_q[65] != par32(d_q[63:32]))};

    // ---------------------------------------------------------------- write ports
    wire q_hit = tq_rpn == e_rpn;
    always_comb begin
        d_we = 1'b0; d_waddr = e_idx; d_wdata = 66'd0;
        t_we = 1'b0; t_waddr = e_idx[13:2]; t_wdata = mk_tag(e_rpn);
        l1_we = 1'b0; l1_waddr = e_addr[9:3]; l1_wdata = 96'd0;
        case (st)
            S_INIT: begin t_we = 1'b1; t_waddr = init_cnt[11:0]; t_wdata = mk_tag(RPN_INVALID); end
            S_IDLE: if (lk_valid && f1_hit && !l1_hit && l1_en) begin
                // L1 fill from the L2 doubleword
                l1_we = 1'b1; l1_waddr = f1_addr[9:3];
                l1_wdata = mk_l1({2'b00, STEER_FILL, f1_rpn, f1_addr[11:10]}, d_q[63:0]);
            end
            S_Q: if (!cur_fill) case (op)
                IC_WI2D: begin
                    d_we = 1'b1;
                    if (op_addr[2]) d_wdata = {d_q[65], par32(op_wdata), d_q[63:32], op_wdata};
                    else            d_wdata = {par32(op_wdata), d_q[64], op_wdata, d_q[31:0]};
                end
                IC_WI2T: begin
                    t_we = 1'b1;
                    t_wdata = {op_wdata[31:12], op_wdata[11], op_wdata[10],
                               op_wdata[6] ? op_wdata[9] : ^op_wdata[31:12]};
                    if (op_wdata[6]) begin
                        d_we = 1'b1; d_waddr = last_wi_idx;
                        d_wdata = last_wi_odd ? {d_q[65], op_wdata[7], d_q[63:0]} : {op_wdata[8], d_q[64], d_q[63:0]};
                    end
                end
                IC_WI1: begin l1_we = 1'b1; l1_wdata = mk_l1(dr29, {dr27, dr28}); end
                default: ;
            endcase
            S_FILLDATA: if (ln_rvalid) begin
                d_we = 1'b1; d_waddr = {e_idx[13:2], ln_rbeat};
                d_wdata = {par32(ln_rdata[63:32]), par32(ln_rdata[31:0]), ln_rdata};
            end
            S_FILLTAG: begin t_we = 1'b1; end
            S_INVAL:   begin t_we = 1'b1; t_wdata = mk_tag(RPN_INVALID); end
            S_L1INV: begin
                l1_we = 1'b1; l1_waddr = {e_addr[9:5], l1cnt};
                l1_wdata = mk_l1({2'b00, STEER_FILL, RPN_INVALID, 2'b00}, 64'd0);
            end
            default: ;
        endcase
    end

    // ---------------------------------------------------------------- line port
    assign ln_req  = st == S_FILLREQ;
    assign ln_addr = {e_rpn, e_addr[11:5], 5'd0};

    // ---------------------------------------------------------------- engine
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            st <= S_INIT; init_cnt <= 13'd0; fill_got <= 4'd0; ferr <= 1'b0; cur_fill <= 1'b0;
            last_wi_odd <= 1'b0; last_wi_idx <= 14'd0; l1cnt <= 2'd0;
            op_done <= 1'b0; op_hit <= 1'b0; op_perr <= 4'd0; op_rdata <= 32'd0;
            fill_done <= 1'b0; fill_err <= 1'b0; rd_dr27 <= 0; rd_dr28 <= 0; rd_dr29 <= 0;
        end else begin
            op_done <= 1'b0; fill_done <= 1'b0;
            case (st)
                S_INIT: begin
                    init_cnt <= init_cnt + 13'd1;
                    if (init_cnt == 13'd4095) st <= S_IDLE;
                end
                S_IDLE: begin
                    // (a request is still high in the cycle its done pulse is seen)
                    if (op_req && !op_done) begin cur_fill <= 1'b0; st <= S_RD; l1cnt <= 2'd0; end
                    else if (fill_req && !fill_done) begin cur_fill <= 1'b1; st <= S_FILLREQ; fill_got <= 4'd0; ferr <= 1'b0; end
                end
                S_RD: st <= S_Q;
                S_Q: case (op)
                    IC_FIC:  st <= q_hit ? S_INVAL : S_L1INV;
                    IC_FICE: st <= tq_valid ? S_INVAL : S_L1INV;
                    IC_RI2D: begin
                        op_rdata <= op_addr[2] ? d_q[31:0] : d_q[63:32];
                        op_hit <= q_hit; op_perr <= q_perr; st <= S_DONE;
                    end
                    IC_RI2T: begin
                        op_rdata <= {tq_rpn, t_q[2], t_q[1], t_q[0], d_q[65], d_q[64], 7'd0};
                        op_hit <= q_hit; op_perr <= q_perr; st <= S_DONE;
                    end
                    IC_WI2D: begin last_wi_odd <= op_addr[2]; last_wi_idx <= op_addr[16:3]; st <= S_DONE; end
                    IC_RI1: begin
                        rd_dr27 <= l1_q[63:32]; rd_dr28 <= l1_q[31:0]; rd_dr29 <= l1_q[95:64];
                        op_hit <= l1_rpn == op_addr[31:12] && l1_qpage == op_addr[11:10];
                        op_perr <= {l1_perr_tag, l1_perr_data, 2'b00};
                        st <= S_DONE;
                    end
                    default: st <= S_DONE;              // IC_WI2T, IC_WI1 (written in S_Q)
                endcase
                S_FILLREQ: if (ln_ack) st <= S_FILLDATA;
                S_FILLDATA: if (ln_rvalid) begin
                    fill_got[ln_rbeat] <= 1'b1;
                    ferr <= ferr | ln_rerr;
                    if ((fill_got | (4'b0001 << ln_rbeat)) == 4'b1111) st <= S_FILLTAG;
                end
                S_FILLTAG: st <= S_DONE;
                S_INVAL: begin st <= S_L1INV; l1cnt <= 2'd0; end
                S_L1INV: begin
                    l1cnt <= l1cnt + 2'd1;
                    if (l1cnt == 2'd3) st <= S_DONE;
                end
                S_DONE: begin
                    st <= S_IDLE;
                    if (cur_fill) begin fill_done <= 1'b1; fill_err <= ferr; end
                    else op_done <= 1'b1;
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
