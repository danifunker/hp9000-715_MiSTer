// Unified TLB of the PA-7100LC (docs/design/cpu.md 2.2-2.4; ERS s.6.1-6.5):
// 64 page entries, fully associative, and 8 block entries, with the PCX-L
// lock-out / lock-in bits, the not-recently-used replacement and the DR8
// diagnose control (replacement pointer, diagnostic and block inserts).
//
// Page entry: tag {space[15:0], vpn[19:0]} + lock-out, lock-in, E (valid),
// used in flip-flops (compared every cycle); the payload {rpn, ar, aid,
// t, d, b, u} in flip-flops too, selected by the one-hot hit. Block entry: all in
// flip-flops, VPN bits 6:12 (PA numbering) compared where the mask says so,
// the RPN assembled from TRANS and the uncompared VPN bits. A page hit wins
// over a block hit (software must not create both).
//
// The lookup is split across the caller's E and M stages (cpu-timing.md
// 4.9): (lk_space, lk_vpn) is the *next* tag -- E's virtual address, or the
// fetch unit's I-LAB refill request through the core's arbiter -- compared
// against every entry during E, and the match vectors are registered when
// `lk_load` is set (the E -> M edge, or any cycle the port is free for the
// I-LAB); the payload select and the outputs follow from those registers in
// M. `lk_tag_r` is the tag they belong to. `lk_use` marks a real translation
// (sets the entry's used bit). An operation's acceptance (`op_accept`) loads
// the operation's tag instead; the core re-fetches the instruction in M
// after every operation (the commit-time flush, or the walker's replay).
//
// Operations (W stage, one at a time, op_req held until op_done; one cycle
// on the shared CAM, then the target walk): the
// inserts (IxTLBA / IxTLBP and the fast forms, also used by the hardware
// walker), PxTLB, PxTLBE. An insert may target several entries (every VPN
// match plus the DR8 pointer); the engine walks them one per cycle.
module pa_tlb
    import pa_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,
    input  logic [31:0] dr8,

    // lookup
    input  logic [15:0] lk_space,
    input  logic [19:0] lk_vpn,
    input  logic        lk_load,        // register the compare of (lk_space, lk_vpn) this edge
    output logic [35:0] lk_tag_r,       // the tag the registered match belongs to
    input  logic        lk_use,
    input  logic [15:0] pid [4],        // CR8/9/12/13: access id at [15:1], write-disable at [0]
    output logic        lk_hit,
    output logic [19:0] lk_rpn,
    output logic [6:0]  lk_ar,
    output logic [14:0] lk_aid,
    output logic        lk_pid_rd, lk_pid_wr,   // the entry's access id matches a PID (read / write allowed)
    output logic        lk_t, lk_d, lk_b, lk_u,

    // operations
    input  logic        op_req,
    input  tlb_op_e     op,
    input  logic [15:0] op_space,
    input  logic [31:0] op_off,         // the offset (vpn = [31:12]; block mask from bits 13:19)
    input  logic [31:0] op_gr,          // GR[r]: IxTLBA: rpn at bits 7:26; IxTLBP: ar 5:11, aid 16:30, t 2, d 3, b 4, u 12
    output logic        op_done,
    output logic        op_accept,      // the operation is accepted this cycle (its tag is compared instead)
    output logic        op_cam          // this cycle the registered match is the operation's: the lookup result is invalid
);
    // ---------------------------------------------------------------- page entries
    logic [35:0] tag [64];
    logic [63:0] lockout, lockin, valid, used;
    // payload {rpn 20, ar 7, aid 15, t, d, b, u} in flip-flops, read through an
    // AND-OR over the one-hot hit (no hit encoder, no RAM in the lookup path;
    // cpu-timing.md 4.3 cut M3). The RPN is written by IxTLBA (which clears the
    // protection), the protection by IxTLBP.
    logic [45:0] pay [64];

    // ---------------------------------------------------------------- block entries
    logic [15:0] b_space [8];
    logic [12:0] b_vpn [8];             // VPN bits 0:12
    logic [6:0]  b_mask [8];            // compare VPN bits 6:12 where 1
    logic [12:0] b_trans [8];
    logic [7:0]  b_lockout, b_valid;
    logic [6:0]  b_ar [8];
    logic [14:0] b_aid [8];
    logic [3:0]  b_flags [8];           // {t, d, b, u}

    typedef enum logic [2:0] { S_IDLE, S_CAM, S_SELECT, S_WALK, S_DONE } st_e;
    st_e st;
    // the operation's tag, captured when the operation is accepted so the CAM
    // cycle (S_CAM) and the target walk start from flip-flops, not from the
    // core's walker/offset muxes (fit 7, cpu-timing.md 4.4)
    logic [35:0] op_tag;

    // ---------------------------------------------------------------- lookup
    // one CAM for the lookup and the operations, compared a cycle ahead of its
    // use and registered: the cycle an operation is accepted it compares the
    // operation's tag instead (the pipeline holds behind the W instruction
    // then, and the core withholds it_ack while op_cam)
    wire is_purge_all_c = op == TLB_PURGE_ALL;
    assign op_accept = st == S_IDLE && op_req && !op_done && !is_purge_all_c;
    assign op_cam = st == S_CAM;
    wire [35:0] n_tag = op_accept ? {op_space, op_off[31:12]} : {lk_space, lk_vpn};
    logic [63:0] n_match, match;
    logic [7:0]  n_bmatch, bmatch;
    always_comb begin
        for (int i = 0; i < 64; i++) n_match[i] = !lockout[i] && tag[i] == n_tag;
        for (int i = 0; i < 8; i++)
            n_bmatch[i] = !b_lockout[i] && b_valid[i] && b_space[i] == n_tag[35:20] &&
                          b_vpn[i][12:7] == n_tag[19:14] &&
                          ((b_vpn[i][6:0] ^ n_tag[13:7]) & b_mask[i]) == 7'd0;
    end
    // registered for M: the raw match (the operations' targets), the valid
    // entries hit (the payload select), the page hit and the block hit/index
    wire [63:0] n_sel = n_match & valid;
    logic [63:0] sel;
    logic        pg_hit, b_hit;
    logic [2:0]  b_idx;
    logic [2:0]  n_bidx;
    always_comb begin
        n_bidx = 3'd0;
        for (int i = 0; i < 8; i++) if (n_bmatch[i]) n_bidx = n_bidx | 3'(i);
    end
    always_ff @(posedge clk) begin
        if (!rst_n) begin match <= 64'd0; bmatch <= 8'd0; lk_tag_r <= 36'd0; sel <= 64'd0; pg_hit <= 1'b0; b_hit <= 1'b0; b_idx <= 3'd0; end
        else if (op_accept || lk_load) begin
            match <= n_match; bmatch <= n_bmatch; lk_tag_r <= n_tag;
            sel <= n_sel; pg_hit <= |n_sel; b_hit <= |n_bmatch; b_idx <= n_bidx;
        end
    end
    wire [19:0] lk_vpn_r = lk_tag_r[19:0];
    // PID match per entry, from registers only (the entry's access id against
    // the four PID registers; id 0 is public): two more payload bits, so the
    // check costs nothing after the payload select (cpu-timing.md 4.10)
    logic [63:0] p_rd, p_wr;
    logic [7:0]  bp_rd, bp_wr;
    function automatic logic [1:0] pid_ok(input logic [14:0] aid);   // {rd, wr}
        pid_ok = (aid == 15'd0) ? 2'b11 : 2'b00;
        for (int k = 0; k < 4; k++)
            if (pid[k][15:1] == aid) begin pid_ok[1] = 1'b1; if (!pid[k][0]) pid_ok[0] = 1'b1; end
    endfunction
    always_comb begin
        for (int i = 0; i < 64; i++) {p_rd[i], p_wr[i]} = pid_ok(pay[i][18:4]);
        for (int i = 0; i < 8; i++)  {bp_rd[i], bp_wr[i]} = pid_ok(b_aid[i]);
    end
    logic [47:0] pl_all;
    always_comb begin
        pl_all = 48'd0;
        for (int i = 0; i < 64; i++) pl_all = pl_all | ({pay[i], p_rd[i], p_wr[i]} & {48{sel[i]}});
    end
    wire [19:0] pl_rpn = pl_all[47:28];
    wire [25:0] pl = pl_all[27:2];
    wire [19:0] b_rpn = {b_trans[b_idx][12:7], (b_trans[b_idx][6:0] & b_mask[b_idx]) | (lk_vpn_r[13:7] & ~b_mask[b_idx]),
                         lk_vpn_r[6:0]};
    always_comb begin
        if (pg_hit) begin
            lk_hit = 1'b1; lk_rpn = pl_rpn; lk_ar = pl[25:19]; lk_aid = pl[18:4];
            {lk_t, lk_d, lk_b, lk_u} = pl[3:0]; {lk_pid_rd, lk_pid_wr} = pl_all[1:0];
        end else begin
            lk_hit = b_hit; lk_rpn = b_rpn; lk_ar = b_ar[b_idx]; lk_aid = b_aid[b_idx];
            {lk_t, lk_d, lk_b, lk_u} = b_flags[b_idx]; {lk_pid_rd, lk_pid_wr} = {bp_rd[b_idx], bp_wr[b_idx]};
        end
    end

    // ---------------------------------------------------------------- operations
    // DR8 (PA numbering): 16 lock-out, 17 lock-in, 18 page force-insert disable,
    // 19:24 pointer, 25 LRU-insert disable, 28:30 block pointer, 31 block force-insert enable
    wire dr8_lockout = dr8[15], dr8_lockin = dr8[14], dr8_force_dis = dr8[13], dr8_lru_dis = dr8[6], dr8_blk_en = dr8[0];
    wire [5:0] dr8_ptr = dr8[12:7];
    wire [2:0] dr8_bptr = dr8[3:1];

    logic [63:0] targets;
    logic        blk_target;
    logic [5:0]  cur;
    logic        any_target;
    // lowest set bit of targets
    always_comb begin
        cur = 6'd0; any_target = 1'b0;
        for (int i = 63; i >= 0; i--) if (targets[i]) begin cur = 6'(i); any_target = 1'b1; end
    end
    // replacement candidate (ERS s.6.2): lowest invalid not locked in, else lowest
    // used = 0 not locked in, else (after clearing used) lowest not locked in
    logic [63:0] cand_inv, cand_nru, cand_any;
    assign cand_inv = ~valid & ~lockin;
    assign cand_nru = ~used & ~lockin;
    assign cand_any = ~lockin;
    function automatic logic [6:0] lowest(input logic [63:0] v);   // {found, index}
        lowest = 7'd0;
        for (int i = 63; i >= 0; i--) if (v[i]) lowest = {1'b1, 6'(i)};
    endfunction
    wire [6:0] low_inv = lowest(cand_inv), low_nru = lowest(cand_nru), low_any = lowest(cand_any);

    wire is_ins_a = op == TLB_INS_A;
    wire is_ins_p = op == TLB_INS_P;
    wire is_purge = op == TLB_PURGE;
    wire is_purge_all = is_purge_all_c;
    // the block entry is a target when DR8 selects block force-insert (with the page
    // force-insert and LRU inserts disabled)
    wire blk_sel = dr8_blk_en && dr8_force_dis && dr8_lru_dis;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            st <= S_IDLE; op_done <= 1'b0; targets <= 64'd0; blk_target <= 1'b0; op_tag <= 36'd0;
            lockout <= {64{1'b1}}; lockin <= {64{1'b1}}; valid <= 64'd0; used <= 64'd0;
            b_lockout <= 8'hFF; b_valid <= 8'd0;
            for (int i = 0; i < 64; i++) begin tag[i] <= 36'd0; pay[i] <= 46'd0; end
            for (int i = 0; i < 8; i++) begin
                b_space[i] <= 0; b_vpn[i] <= 0; b_mask[i] <= 0; b_trans[i] <= 0; b_ar[i] <= 0; b_aid[i] <= 0; b_flags[i] <= 0;
            end
        end else begin
            op_done <= 1'b0;
            if (lk_use && !op_cam) used <= used | sel;
            case (st)
                S_IDLE: if (op_req && !op_done) begin
                    blk_target <= 1'b0;
                    if (is_purge_all) begin
                        valid <= 64'd0;
                        st <= S_DONE;
                    end else
                        st <= S_CAM;                    // the match registers load op_tag's compare now
                    op_tag <= {op_space, op_off[31:12]};
                end
                S_CAM: begin                            // match = the entries with op_tag
                    st <= S_SELECT;
                    targets <= match;
                    if (blk_sel) blk_target <= 1'b1;
                    if (is_ins_a) begin
                        if (!dr8_force_dis) targets <= match | (64'd1 << dr8_ptr);
                        else if (match == 64'd0 && !dr8_lru_dis && !blk_sel) begin
                            // normal replacement
                            if (low_inv[6])      targets <= 64'd1 << low_inv[5:0];
                            else if (low_nru[6]) targets <= 64'd1 << low_nru[5:0];
                            else begin
                                used <= 64'd0;
                                if (low_any[6]) targets <= 64'd1 << low_any[5:0];
                            end
                        end
                    end
                end
                S_SELECT: st <= S_WALK;                 // targets settled
                S_WALK: begin
                    if (any_target) begin
                        targets[cur] <= 1'b0;
                        if (is_ins_a) begin
                            tag[cur] <= op_tag;
                            valid[cur] <= 1'b0;
                            lockout[cur] <= dr8_lockout;
                            lockin[cur] <= dr8_lockin;
                            pay[cur] <= {op_gr[24:5], 26'd0};
                        end else if (is_ins_p) begin
                            valid[cur] <= 1'b1;
                            pay[cur][25:0] <= {op_gr[26:20], op_gr[15:1], op_gr[29], op_gr[28], op_gr[27], op_gr[19]};
                        end else if (is_purge) begin
                            valid[cur] <= 1'b0;
                        end
                    end else if (blk_target) begin
                        blk_target <= 1'b0;
                        if (is_ins_a) begin
                            b_space[dr8_bptr] <= op_space;
                            b_vpn[dr8_bptr] <= op_off[31:19];
                            b_mask[dr8_bptr] <= op_off[18:12];
                            b_trans[dr8_bptr] <= op_gr[24:12];
                            b_valid[dr8_bptr] <= 1'b0;
                            b_lockout[dr8_bptr] <= dr8_lockout;
                            b_ar[dr8_bptr] <= 7'd0; b_aid[dr8_bptr] <= 15'd0; b_flags[dr8_bptr] <= 4'd0;
                        end else if (is_ins_p) begin
                            b_valid[dr8_bptr] <= 1'b1;
                            b_ar[dr8_bptr] <= op_gr[26:20]; b_aid[dr8_bptr] <= op_gr[15:1];
                            b_flags[dr8_bptr] <= {op_gr[29], op_gr[28], op_gr[27], op_gr[19]};
                        end else if (is_purge) begin
                            b_valid[dr8_bptr] <= 1'b0;
                        end
                    end else st <= S_DONE;
                end
                S_DONE: begin op_done <= 1'b1; st <= S_IDLE; end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
