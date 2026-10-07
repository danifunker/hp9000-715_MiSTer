// Instruction fetch for the pipelined core (docs/design/cpu.md 6.2, 6.5).
//
// Two fetch stages. F1 holds the address of the instruction being fetched
// (in the cached core this is the cycle the I-cache RAMs are read); F2 holds
// the fetched word and is the stage the core's D register loads from. The
// fetch state (nf, nb) = IAOQ front/back of the next instruction to issue:
// issuing tags the instruction with (nf, nb) and then nf <- nb, nb <- nb + 4.
//
// Redirects (one rule, cpu.md 6.2): a taken branch X with target T changes
// the instruction *after* X's successor Y (the delay slot): Y keeps its own
// address but its IAOQ back becomes T, everything younger than Y is killed
// and fetching resumes at (T, T + 4). The core patches Y when Y is in D (or
// entering D); here Y is found by its address among F2/F1 (it is the only
// instruction whose IAOQ front equals X's IAOQ back), patched, and every
// other valid entry is killed. A W redirect (interruption, RFI, flush after
// a serialising instruction) has no delay slot: everything is killed.
//
// Cacheable code (PA < 0xF0000000) is looked up in the I-caches (pa_icache)
// during F1: the lookup is issued with the address of the instruction
// entering F1 and the word, hit and parity flags are read at the end of F1.
// Uncached code (the ROM, I/O space): a one-line uncached fetch buffer (UIB)
// holds the last 32-byte burst. Misses of either kind are non-speculative:
// the fill or burst is issued only once every older instruction has
// committed (drained) and the store buffer is empty, so wrong-path fetches
// never reach the bus (BOOT s.4.5). A bus error marks the instruction
// (fetch_err); the core takes the HPMC on it.
//
// Virtual mode (PSW.C): the one-entry I-LAB (ERS s.6.4) holds the current
// page's translation {space, vpn, rpn, execute rights per PL, AR type}; a
// fetch outside it asks the core for a TLB lookup (the M stage has priority)
// and reloads the I-LAB, or marks the instruction ITLB-miss (it then goes
// down the pipeline as a NOP for W to walk or trap on). The I-LAB is
// invalidated by every W redirect, which covers RFI, the TLB and PID
// writes and PSW.C changes (all serialising).
module pa_fetch (
    input  logic        clk,
    input  logic        rst_n,
    // fetch state control
    input  logic        adv_f2,         // F2 -> D moves this cycle
    input  logic        drained,        // D, E, M, W empty: a miss may go to the bus
    input  logic        uib_inval,      // SYNC / FIC / uncached store into the line
    input  logic        psw_c,          // code translation
    input  logic [4:0]  ihash,          // bit 0 = DR0 IHASH_EN
    // I-LAB refill through the core's TLB arbiter
    output logic        it_req,
    output logic [15:0] it_space,
    output logic [19:0] it_vpn,
    input  logic        it_ack,
    input  logic        it_hit,
    input  logic [19:0] it_rpn,
    input  logic [3:0]  it_xok,         // execute allowed, per PL
    input  logic [2:0]  it_type,        // AR type (GATE promotion)
    // redirect (priority: W kill-all > branch)
    input  logic        redir,          // a branch redirect (from D or E)
    input  logic        redir_kill_all, // W: interruption / RFI / flush
    input  logic [31:0] redir_target,
    input  logic [31:0] redir_back,     // kill-all: the IAOQ back of the first new instruction
    input  logic [15:0] redir_space, redir_back_space,
    input  logic        redir_new_space,
    input  logic [31:0] redir_slot,     // IAOQ front of the branch's delay slot
    // F2 -> D
    output logic        f2_valid,
    output logic [31:0] f2_insn,
    output logic [31:0] f2_iaoq_f, f2_iaoq_b,
    output logic [15:0] f2_iasq_f, f2_iasq_b,
    output logic        f2_err,
    output logic [3:0]  f2_perr,        // I-cache parity flags of the fetched word
    output logic        f2_itlb,        // ITLB miss (the word is a NOP)
    output logic        f2_imp,         // no execute rights at this PL (trap 7)
    output logic [2:0]  f2_type,        // the page's AR type
    // I-cache lookup and fill
    output logic        ic_lk_en,
    output logic [31:0] ic_lk_addr,
    output logic [4:0]  ic_lk_hash,
    output logic [31:0] ic_f1_addr,     // the instruction in F1 (for the hit compare)
    output logic [19:0] ic_f1_rpn,
    input  logic        ic_lk_valid,
    input  logic        ic_busy,
    input  logic [31:0] ic_word,
    input  logic        ic_hit,
    input  logic [3:0]  ic_perr,
    output logic        ic_fill_req,
    output logic [31:0] ic_fill_addr,
    output logic [4:0]  ic_fill_hash,
    output logic [19:0] ic_fill_rpn,
    input  logic        ic_fill_done,
    input  logic        ic_fill_err,
    // BIU burst port
    output logic        f_req,
    output logic [31:0] f_addr,
    input  logic        f_beat,
    input  logic [1:0]  f_beat_idx,
    input  logic [63:0] f_data,
    input  logic        f_done,
    input  logic        f_err
);
    // ---------------------------------------------------------------- state
    logic [31:0] nf, nb;
    logic [15:0] nsf, nsb;
    logic        f1_valid;
    logic [31:0] f1_iaoq_f, f1_iaoq_b;
    logic [15:0] f1_iasq_f, f1_iasq_b;

    // UIB
    logic [63:0] uib [4];
    logic [26:0] uib_tag;
    logic        uib_valid, uib_err;
    logic        burst;                 // a burst is in flight for f1

    // ---- I-LAB
    logic        ilab_valid;
    logic [15:0] ilab_space;
    logic [19:0] ilab_vpn, ilab_rpn;
    logic [3:0]  ilab_xok;
    logic [2:0]  ilab_type;
    logic        f1_tmiss;              // F1's page is not in the TLB
    wire ilab_hit = ilab_valid && ilab_space == f1_iasq_f && ilab_vpn == f1_iaoq_f[31:12];
    wire f1_virt  = psw_c;
    wire f1_xlat  = !f1_virt || ilab_hit;                       // translation known
    wire [31:0] f1_pa = f1_virt ? {ilab_rpn, f1_iaoq_f[11:0]} : f1_iaoq_f;
    assign it_req   = f1_valid && f1_virt && !ilab_hit && !f1_tmiss;
    assign it_space = f1_iasq_f;
    assign it_vpn   = f1_iaoq_f[31:12];

    wire uib_hit  = uib_valid && uib_tag == f1_pa[31:5];
    wire f1_io    = f1_pa[31:28] == 4'hF;
    logic f1_ferr;                      // the I-cache fill that served F1 had a bus error
    wire f1_ready = f1_valid && (f1_tmiss || (f1_xlat && (f1_io ? uib_hit : ic_hit)));
    wire [63:0] uib_dw = uib[f1_iaoq_f[4:3]];
    wire [31:0] f1_word = f1_tmiss ? 32'h0800_0240 : f1_io ? (f1_iaoq_f[2] ? uib_dw[31:0] : uib_dw[63:32]) : ic_word;
    wire        f1_err  = !f1_tmiss && (f1_io ? uib_err : f1_ferr);
    wire [3:0]  f1_perr = (f1_io || f1_tmiss) ? 4'd0 : ic_perr;
    wire        f1_imp  = f1_virt && !f1_tmiss && !ilab_xok[f1_iaoq_f[1:0]];

    // I-cache: look up the instruction entering F1; re-issue F1's lookup when
    // the engine took the read port in between
    logic issue;
    wire reissue = f1_valid && !f1_io && !ic_lk_valid && !ic_busy && !issue;
    function automatic logic [4:0] ihash_of(input logic [15:0] sp);
        return ihash[0] ? {sp[4], sp[3], sp[0], sp[1], sp[2]} : 5'd0;
    endfunction
    assign ic_lk_en   = issue || reissue;
    assign ic_lk_addr = issue ? nf : f1_iaoq_f;
    assign ic_lk_hash = psw_c ? ihash_of(issue ? nsf : f1_iasq_f) : 5'd0;
    assign ic_f1_addr = f1_iaoq_f;
    assign ic_f1_rpn  = f1_pa[31:12];

    // issue a burst for a missing F1 once the pipeline has drained
    assign f_req  = burst;
    assign f_addr = {uib_tag, 5'd0};

    // ---------------------------------------------------------------- next state
    logic        n_f1_valid, n_f2_valid;
    logic [31:0] n_f1_iaoq_f, n_f1_iaoq_b, n_f2_iaoq_f, n_f2_iaoq_b;
    logic [15:0] n_f1_iasq_f, n_f1_iasq_b, n_f2_iasq_f, n_f2_iasq_b;
    logic [31:0] n_f2_insn;
    logic        n_f2_err, n_f2_itlb, n_f2_imp;
    logic [3:0]  n_f2_perr;
    logic [2:0]  n_f2_type;
    logic [31:0] n_nf, n_nb;
    logic [15:0] n_nsf, n_nsb;
    logic        f1_consumed;

    always_comb begin
        n_f1_valid = f1_valid; n_f1_iaoq_f = f1_iaoq_f; n_f1_iaoq_b = f1_iaoq_b;
        n_f1_iasq_f = f1_iasq_f; n_f1_iasq_b = f1_iasq_b;
        n_f2_valid = f2_valid; n_f2_iaoq_f = f2_iaoq_f; n_f2_iaoq_b = f2_iaoq_b;
        n_f2_iasq_f = f2_iasq_f; n_f2_iasq_b = f2_iasq_b; n_f2_insn = f2_insn; n_f2_err = f2_err;
        n_f2_perr = f2_perr; n_f2_itlb = f2_itlb; n_f2_imp = f2_imp; n_f2_type = f2_type;
        n_nf = nf; n_nb = nb; n_nsf = nsf; n_nsb = nsb;
        f1_consumed = 1'b0;

        // 1. advance
        if (adv_f2) begin
            n_f2_valid = f1_ready;
            n_f2_iaoq_f = f1_iaoq_f; n_f2_iaoq_b = f1_iaoq_b;
            n_f2_iasq_f = f1_iasq_f; n_f2_iasq_b = f1_iasq_b;
            n_f2_insn = f1_word; n_f2_err = f1_err; n_f2_perr = f1_perr;
            n_f2_itlb = f1_tmiss; n_f2_imp = f1_imp; n_f2_type = f1_virt ? ilab_type : 3'd0;
            f1_consumed = f1_ready;
        end
        issue = !f1_valid || f1_consumed;
        if (issue) begin
            n_f1_valid = 1'b1;
            n_f1_iaoq_f = nf; n_f1_iaoq_b = nb; n_f1_iasq_f = nsf; n_f1_iasq_b = nsb;
            n_nf = nb; n_nb = nb + 32'd4; n_nsf = nsb;
        end

        // 2. redirect, applied to the advanced state
        if (redir_kill_all) begin
            n_f1_valid = 1'b0; n_f2_valid = 1'b0;
            n_nf = redir_target; n_nb = redir_back;
            n_nsf = redir_space; n_nsb = redir_back_space;
        end else if (redir) begin
            if (n_f2_valid && n_f2_iaoq_f == redir_slot) begin
                n_f2_iaoq_b = redir_target;
                if (redir_new_space) n_f2_iasq_b = redir_space;
            end else
                n_f2_valid = 1'b0;
            if (n_f1_valid && n_f1_iaoq_f == redir_slot) begin
                n_f1_iaoq_b = redir_target;
                if (redir_new_space) n_f1_iasq_b = redir_space;
            end else
                n_f1_valid = 1'b0;
            n_nf = redir_target; n_nb = redir_target + 32'd4;
            n_nsf = redir_new_space ? redir_space : n_nsb;
            n_nsb = n_nsf;
        end
    end

    // ---------------------------------------------------------------- registers
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            nf <= 32'hF000_0004; nb <= 32'hF000_0008; nsf <= 16'd0; nsb <= 16'd0;
            f1_valid <= 1'b0; f2_valid <= 1'b0;
            f1_iaoq_f <= 0; f1_iaoq_b <= 0; f1_iasq_f <= 0; f1_iasq_b <= 0;
            f2_iaoq_f <= 0; f2_iaoq_b <= 0; f2_iasq_f <= 0; f2_iasq_b <= 0; f2_insn <= 0; f2_err <= 0;
            f2_perr <= 0; f2_itlb <= 0; f2_imp <= 0; f2_type <= 0; f1_ferr <= 1'b0; f1_tmiss <= 1'b0; ic_fill_req <= 1'b0;
            ilab_valid <= 1'b0; ilab_space <= 0; ilab_vpn <= 0; ilab_rpn <= 0; ilab_xok <= 0; ilab_type <= 0;
            ic_fill_addr <= 0; ic_fill_hash <= 0; ic_fill_rpn <= 0;
            uib_valid <= 1'b0; uib_err <= 1'b0; uib_tag <= 27'd0; burst <= 1'b0;
            for (int i = 0; i < 4; i++) uib[i] <= 64'd0;
        end else begin
            f1_valid <= n_f1_valid; f1_iaoq_f <= n_f1_iaoq_f; f1_iaoq_b <= n_f1_iaoq_b;
            f1_iasq_f <= n_f1_iasq_f; f1_iasq_b <= n_f1_iasq_b;
            f2_valid <= n_f2_valid; f2_iaoq_f <= n_f2_iaoq_f; f2_iaoq_b <= n_f2_iaoq_b;
            f2_iasq_f <= n_f2_iasq_f; f2_iasq_b <= n_f2_iasq_b; f2_insn <= n_f2_insn; f2_err <= n_f2_err;
            f2_perr <= n_f2_perr; f2_itlb <= n_f2_itlb; f2_imp <= n_f2_imp; f2_type <= n_f2_type;
            nf <= n_nf; nb <= n_nb; nsf <= n_nsf; nsb <= n_nsb;
            if (issue) begin f1_ferr <= 1'b0; f1_tmiss <= 1'b0; end

            // I-LAB refill
            if (it_ack) begin
                if (it_hit) begin
                    ilab_valid <= 1'b1; ilab_space <= it_space; ilab_vpn <= it_vpn; ilab_rpn <= it_rpn;
                    ilab_xok <= it_xok; ilab_type <= it_type;
                end else f1_tmiss <= 1'b1;
            end
            if (redir_kill_all) ilab_valid <= 1'b0;

            // I-cache line fill: non-speculative, only for a missing, unkilled F1
            if (ic_fill_req) begin
                if (ic_fill_done) begin ic_fill_req <= 1'b0; f1_ferr <= ic_fill_err; end
            end else if (f1_valid && f1_xlat && !f1_tmiss && !f1_io && !ic_hit && ic_lk_valid && !ic_busy &&
                         drained && !f2_valid && !redir && !redir_kill_all) begin
                ic_fill_req <= 1'b1;
                ic_fill_addr <= f1_iaoq_f;
                ic_fill_hash <= psw_c ? ihash_of(f1_iasq_f) : 5'd0;
                ic_fill_rpn <= f1_pa[31:12];
            end

            // UIB fill: non-speculative, only for a missing, unkilled F1
            if (!burst) begin
                if (f1_valid && f1_xlat && !f1_tmiss && f1_io && !uib_hit && drained && !f2_valid && !redir && !redir_kill_all) begin
                    burst <= 1'b1;
                    uib_valid <= 1'b0;
                    uib_tag <= f1_pa[31:5];
                end
            end else begin
                if (f_beat) uib[f_beat_idx] <= f_data;
                if (f_done) begin
                    burst <= 1'b0;
                    uib_valid <= 1'b1;
                    uib_err <= f_err;
                end
            end
            if (uib_inval && !burst) uib_valid <= 1'b0;
        end
    end
endmodule
