// L2 data cache: 128 KB direct-mapped, 32-byte lines, write-back,
// write-allocate, one data word parity bit per word, the PCX-L tag format
// (docs/design/cpu.md 2.7, 5.4, 5.5, 6.6; ERS s.8.3.4-8.3.6).
//
//   data RAM  16K x 66: {parity of word 0, parity of word 1, doubleword}
//   tag RAM    4K x 23: {RPN[19:0], dirty, dirty parity (odd), tag parity (even)}
//   invalid    RPN = 0xF0000 (I/O space never matches: tag word 0xF0000400)
//
// Lookup (M stage): the address register of both RAMs loads from lk_addr
// when the E -> M move happens (lk_en) and holds otherwise, so the RAM
// outputs stay those of the instruction in M for as long as it is there.
// hit = tag RPN == m_addr[31:12] (real mode; the TLB supplies the RPN
// later). A load in M takes its doubleword from the store committing in W
// or the one before it when they wrote that doubleword (the M10K returns
// old data during a write and for one more cycle).
//
// W-stage operations (op_req / op_done): a miss (victim write-back if dirty,
// line fill, the core then replays the instruction), FDC/FDCE/PDC, the LDCW
// cache check, and the diagnose reads/writes RDD/RDT/WDD/WDT. They own the
// read port while they run; the core flushes every younger instruction
// afterwards, so the lookup in M is never resumed.
//
// After reset the tag array is written invalid (4096 cycles); `ready` holds
// cacheable accesses until then (the ROM runs from the UIB meanwhile).
module pa_dcache
    import pa_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,
    output logic        ready,

    // M-stage lookup
    input  logic        lk_en,          // E -> M this cycle
    input  logic [31:0] lk_addr,        // VA
    input  logic [4:0]  lk_hash,        // XORed into index bits 16:12 (the space hash, cpu.md 2.7)
    input  logic [31:0] m_addr,         // the instruction in M (registered lk_addr)
    input  logic [19:0] m_rpn,          // its RPN (translated, or the address in real mode)
    output logic [63:0] m_rdata,
    output logic        m_hit,
    output logic        m_dirty,
    output logic [3:0]  m_perr,         // {dirty parity, tag parity, word 1, word 0} mismatch

    // W: store commit (hit only)
    input  logic        st_we,
    input  logic        st_fwd,         // a store sits in W that will write st_addr (forwarding select)
    input  logic [31:0] st_addr,
    input  logic [4:0]  st_hash,
    input  logic [19:0] st_rpn,
    input  logic [63:0] st_data,        // the merged doubleword

    // W: multi-cycle operations
    input  logic        op_req,         // level, dropped with op_done
    input  dc_op_e      op,
    input  logic [31:0] op_addr,
    input  logic [4:0]  op_hash,
    input  logic [19:0] op_rpn,
    input  logic [31:0] op_wdata,       // WDD: GR[x]; WDT: the SET_TAG latch
    output logic [127:0] op_rd2,        // DC_RD2: the 16 bytes at op_addr (the walker's PDIR entry)
    output logic        op_done,        // one cycle
    output logic        op_err,         // fill: bus error
    output logic        op_hit,         // RDD/RDT: tag match; LDCW: hit and dirty
    output logic [3:0]  op_perr,        // as m_perr, for the diagnose read
    output logic [31:0] op_rdata,

    // line port
    output logic        ln_req, ln_we,
    output logic [31:0] ln_addr,
    input  logic        ln_ack,
    output logic [63:0] ln_wdata,
    output logic        ln_wvalid,
    input  logic        ln_wready,
    input  logic [63:0] ln_rdata,
    input  logic        ln_rvalid,
    input  logic [1:0]  ln_rbeat,
    input  logic        ln_rerr
);
    localparam logic [19:0] RPN_INVALID = 20'hF0000;

    // ---------------------------------------------------------------- RAMs
    logic [13:0] d_raddr, d_waddr;
    logic [65:0] d_q, d_wdata;
    logic        d_we, d_ren;
    logic [11:0] t_raddr, t_waddr;
    logic [22:0] t_q, t_wdata;
    logic        t_we;
    pa_cache_ram #(.WIDTH(66), .DEPTH_LOG2(14)) u_data (
        .clk(clk), .raddr(d_raddr), .ren(d_ren), .rdata(d_q), .we(d_we), .waddr(d_waddr), .wdata(d_wdata));
    pa_cache_ram #(.WIDTH(23), .DEPTH_LOG2(12)) u_tag (
        .clk(clk), .raddr(t_raddr), .ren(d_ren), .rdata(t_q), .we(t_we), .waddr(t_waddr), .wdata(t_wdata));

    function automatic logic par32(input logic [31:0] w); return ^w; endfunction
    function automatic logic [22:0] mk_tag(input logic [19:0] rpn, input logic dirty);
        return {rpn, dirty, ~dirty, ^rpn};
    endfunction
    wire [19:0] tq_rpn   = t_q[22:3];
    wire        tq_dirty = t_q[2];
    wire        tq_dpar  = t_q[1];
    wire        tq_tpar  = t_q[0];
    wire        tq_valid = tq_rpn != RPN_INVALID;
    wire [3:0]  q_perr   = {tq_dpar != ~tq_dirty, tq_tpar != ^tq_rpn,
                            d_q[64] != par32(d_q[31:0]), d_q[65] != par32(d_q[63:32])};

    // ---------------------------------------------------------------- state
    typedef enum logic [3:0] {
        S_INIT, S_IDLE, S_RD, S_Q, S_WBRD, S_WBREQ, S_WBDATA, S_FILLREQ, S_FILLDATA, S_FILLTAG,
        S_INVAL, S_DONE, S_RD2
    } st_e;
    st_e         st;
    logic [12:0] init_cnt;
    logic [63:0] linebuf [4];
    logic [2:0]  cnt;
    logic [3:0]  fill_got;
    logic        fill_err;
    logic [19:0] vic_rpn;
    logic        last_wdd_odd;         // the last WDD wrote the odd word
    logic [13:0] last_wdd_idx;
    logic        prev_st_valid;
    logic [28:0] prev_st_addr;
    logic [63:0] prev_st_data;

    assign ready = st != S_INIT;
    wire busy = st != S_IDLE;

    // ---------------------------------------------------------------- read port
    wire [13:0] lk_idx = {lk_addr[16:12] ^ lk_hash, lk_addr[11:3]};
    wire [13:0] op_idx = {op_addr[16:12] ^ op_hash, op_addr[11:3]};
    wire [13:0] st_idx = {st_addr[16:12] ^ st_hash, st_addr[11:3]};
    always_comb begin
        d_ren   = 1'b1;
        d_raddr = lk_idx;
        t_raddr = lk_idx[13:2];
        if (busy) begin
            // the engine reads: a line beat during write-back reads, else the op address
            d_raddr = (st == S_WBRD) ? {op_idx[13:2], cnt[1:0]} : (op == DC_WDT) ? last_wdd_idx :
                      (st == S_Q && op == DC_RD2) ? {op_idx[13:1], 1'b1} : op_idx;
            t_raddr = op_idx[13:2];
        end else if (!lk_en) d_ren = 1'b0;
    end

    // ---------------------------------------------------------------- M results
    wire fwd1 = st_fwd && st_addr[31:3] == m_addr[31:3];
    wire fwd2 = prev_st_valid && prev_st_addr == m_addr[31:3];
    assign m_rdata = fwd1 ? st_data : fwd2 ? prev_st_data : d_q[63:0];
    assign m_hit   = tq_rpn == m_rpn;
    assign m_dirty = tq_dirty;
    assign m_perr  = (fwd1 || fwd2) ? {q_perr[3:2], 2'b00} : q_perr;

    // ---------------------------------------------------------------- write port
    always_comb begin
        d_we = 1'b0; d_waddr = st_idx;
        d_wdata = {par32(st_data[63:32]), par32(st_data[31:0]), st_data};
        t_we = 1'b0; t_waddr = st_idx[13:2]; t_wdata = mk_tag(st_rpn, 1'b1);
        case (st)
            S_INIT: begin
                t_we = 1'b1; t_waddr = init_cnt[11:0]; t_wdata = mk_tag(RPN_INVALID, 1'b0);
            end
            S_IDLE: if (st_we) begin d_we = 1'b1; t_we = 1'b1; end
            S_Q: case (op)
                DC_WDD: begin
                    d_we = 1'b1; d_waddr = op_idx;
                    if (op_addr[2]) d_wdata = {d_q[65], par32(op_wdata), d_q[63:32], op_wdata};
                    else            d_wdata = {par32(op_wdata), d_q[64], op_wdata, d_q[31:0]};
                end
                DC_WDT: begin
                    // tag from the SET_TAG latch: RPN 0:19, dirty 20, dirty parity 21 (always
                    // from the latch), tag parity 22 (from the latch when Arb 25 = 1)
                    t_we = 1'b1; t_waddr = op_idx[13:2];
                    t_wdata = {op_wdata[31:12], op_wdata[11], op_wdata[10],
                               op_wdata[6] ? op_wdata[9] : ^op_wdata[31:12]};
                    if (op_wdata[6]) begin        // arbitrary parity for the last WDD word too
                        d_we = 1'b1; d_waddr = last_wdd_idx;
                        d_wdata = last_wdd_odd ? {d_q[65], op_wdata[7], d_q[63:0]}
                                               : {op_wdata[8], d_q[64], d_q[63:0]};
                    end
                end
                default: ;
            endcase
            S_FILLDATA: if (ln_rvalid) begin
                d_we = 1'b1; d_waddr = {op_idx[13:2], ln_rbeat};
                d_wdata = {par32(ln_rdata[63:32]), par32(ln_rdata[31:0]), ln_rdata};
            end
            S_FILLTAG: begin t_we = 1'b1; t_waddr = op_idx[13:2]; t_wdata = mk_tag(op_rpn, 1'b0); end
            S_INVAL:   begin t_we = 1'b1; t_waddr = op_idx[13:2]; t_wdata = mk_tag(RPN_INVALID, 1'b0); end
            default: ;
        endcase
    end

    // ---------------------------------------------------------------- line port
    always_comb begin
        ln_req = 1'b0; ln_we = 1'b0; ln_addr = {op_rpn, op_addr[11:5], 5'd0};
        ln_wvalid = 1'b0; ln_wdata = linebuf[cnt[1:0]];
        case (st)
            S_WBREQ:  begin ln_req = 1'b1; ln_we = 1'b1; ln_addr = {vic_rpn, op_addr[11:5], 5'd0}; end
            S_WBDATA: begin ln_wvalid = 1'b1; end
            S_FILLREQ: begin ln_req = 1'b1; end
            default: ;
        endcase
    end

    // ---------------------------------------------------------------- engine
    wire q_hit = tq_rpn == op_rpn;
    wire wb_needed = tq_valid && tq_dirty && tq_rpn[19:16] != 4'hF;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            st <= S_INIT; init_cnt <= 13'd0; cnt <= 3'd0; fill_got <= 4'd0; fill_err <= 1'b0;
            vic_rpn <= 20'd0; last_wdd_odd <= 1'b0; last_wdd_idx <= 14'd0;
            prev_st_valid <= 1'b0; prev_st_addr <= 29'd0; prev_st_data <= 64'd0;
            op_done <= 1'b0; op_err <= 1'b0; op_hit <= 1'b0; op_perr <= 4'd0; op_rdata <= 32'd0; op_rd2 <= 128'd0;
            for (int i = 0; i < 4; i++) linebuf[i] <= 64'd0;
        end else begin
            op_done <= 1'b0;
            prev_st_valid <= st_we;
            if (st_we) begin prev_st_addr <= st_addr[31:3]; prev_st_data <= st_data; end
            case (st)
                S_INIT: begin
                    init_cnt <= init_cnt + 13'd1;
                    if (init_cnt == 13'd4095) st <= S_IDLE;
                end
                S_IDLE: if (op_req && !op_done) begin
                    st <= S_RD; op_err <= 1'b0; fill_got <= 4'd0; fill_err <= 1'b0; cnt <= 3'd0;
                end
                S_RD: st <= S_Q;                        // RAM outputs valid next cycle
                S_Q: case (op)
                    DC_MISS: begin
                        vic_rpn <= tq_rpn;
                        st <= wb_needed ? S_WBRD : S_FILLREQ;
                    end
                    DC_RD2: begin
                        // the walker's PDIR entry: 16 bytes, through the cache (fill on a miss)
                        if (q_hit) begin op_rd2[127:64] <= d_q[63:0]; st <= S_RD2; end
                        else begin vic_rpn <= tq_rpn; st <= wb_needed ? S_WBRD : S_FILLREQ; end
                    end
                    DC_FDC, DC_FDCE, DC_PDC: begin
                        vic_rpn <= tq_rpn;
                        if (op == DC_FDCE ? tq_valid : q_hit) begin
                            if (wb_needed && op != DC_PDC) st <= S_WBRD;
                            else st <= S_INVAL;
                        end else st <= S_DONE;
                    end
                    DC_LDCW: begin
                        op_hit <= q_hit && tq_dirty;
                        st <= (q_hit && !tq_dirty) ? S_INVAL : S_DONE;
                    end
                    DC_RDD: begin
                        op_rdata <= op_addr[2] ? d_q[31:0] : d_q[63:32];
                        op_hit <= q_hit; op_perr <= q_perr; st <= S_DONE;
                    end
                    DC_RDT: begin
                        op_rdata <= {tq_rpn, tq_dirty, tq_dpar, tq_tpar, d_q[65], d_q[64], 7'd0};
                        op_hit <= q_hit; op_perr <= q_perr; st <= S_DONE;
                    end
                    DC_WDD: begin
                        last_wdd_odd <= op_addr[2]; last_wdd_idx <= op_addr[16:3]; st <= S_DONE;
                    end
                    default: st <= S_DONE;               // DC_WDT
                endcase
                S_RD2: begin op_rd2[63:0] <= d_q[63:0]; st <= S_DONE; end
                // victim write-back: read the four doublewords, then send them
                S_WBRD: begin
                    // d_q holds doubleword cnt-1 (the address was applied a cycle earlier)
                    if (cnt != 0) linebuf[cnt[1:0] - 2'd1] <= d_q[63:0];
                    cnt <= cnt + 3'd1;
                    if (cnt == 3'd4) begin st <= S_WBREQ; cnt <= 3'd0; end
                end
                S_WBREQ: if (ln_ack) st <= S_WBDATA;
                S_WBDATA: if (ln_wready) begin
                    cnt <= cnt + 3'd1;
                    if (cnt[1:0] == 2'd3) begin
                        cnt <= 3'd0;
                        st <= (op == DC_MISS) ? S_FILLREQ : S_INVAL;
                    end
                end
                S_FILLREQ: if (ln_ack) st <= S_FILLDATA;
                S_FILLDATA: if (ln_rvalid) begin
                    fill_got[ln_rbeat] <= 1'b1;
                    fill_err <= fill_err | ln_rerr;
                    if ((fill_got | (4'b0001 << ln_rbeat)) == 4'b1111) st <= S_FILLTAG;
                end
                S_FILLTAG: begin
                    op_err <= fill_err;
                    st <= (op == DC_RD2 && !fill_err) ? S_RD : S_DONE;   // the walker then reads the filled line
                end
                S_INVAL: st <= S_DONE;
                S_DONE: begin op_done <= 1'b1; st <= S_IDLE; end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
