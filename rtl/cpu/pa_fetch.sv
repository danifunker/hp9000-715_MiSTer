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
// Uncached code (the ROM): a one-line uncached fetch buffer (UIB) holds the
// last 32-byte burst. A miss is non-speculative: the burst is issued only
// once every older instruction has committed (drained) and the store buffer
// is empty, so wrong-path fetches never reach the bus (BOOT s.4.5). A bus
// error marks the instruction (fetch_err); the core takes the HPMC on it.
// Until the caches exist every fetch goes through the UIB (STUBS S-005).
module pa_fetch (
    input  logic        clk,
    input  logic        rst_n,
    // fetch state control
    input  logic        adv_f2,         // F2 -> D moves this cycle
    input  logic        drained,        // D, E, M, W empty: a miss may go to the bus
    input  logic        uib_inval,      // SYNC / FIC / uncached store into the line
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

    wire uib_hit  = uib_valid && uib_tag == f1_iaoq_f[31:5];
    wire f1_ready = f1_valid && uib_hit;
    wire [63:0] uib_dw = uib[f1_iaoq_f[4:3]];
    wire [31:0] f1_word = f1_iaoq_f[2] ? uib_dw[31:0] : uib_dw[63:32];

    // issue a burst for a missing F1 once the pipeline has drained
    assign f_req  = burst;
    assign f_addr = {f1_iaoq_f[31:5], 5'd0};

    // ---------------------------------------------------------------- next state
    logic        n_f1_valid, n_f2_valid;
    logic [31:0] n_f1_iaoq_f, n_f1_iaoq_b, n_f2_iaoq_f, n_f2_iaoq_b;
    logic [15:0] n_f1_iasq_f, n_f1_iasq_b, n_f2_iasq_f, n_f2_iasq_b;
    logic [31:0] n_f2_insn;
    logic        n_f2_err;
    logic [31:0] n_nf, n_nb;
    logic [15:0] n_nsf, n_nsb;
    logic        f1_consumed, issue;

    always_comb begin
        n_f1_valid = f1_valid; n_f1_iaoq_f = f1_iaoq_f; n_f1_iaoq_b = f1_iaoq_b;
        n_f1_iasq_f = f1_iasq_f; n_f1_iasq_b = f1_iasq_b;
        n_f2_valid = f2_valid; n_f2_iaoq_f = f2_iaoq_f; n_f2_iaoq_b = f2_iaoq_b;
        n_f2_iasq_f = f2_iasq_f; n_f2_iasq_b = f2_iasq_b; n_f2_insn = f2_insn; n_f2_err = f2_err;
        n_nf = nf; n_nb = nb; n_nsf = nsf; n_nsb = nsb;
        f1_consumed = 1'b0;

        // 1. advance
        if (adv_f2) begin
            n_f2_valid = f1_ready;
            n_f2_iaoq_f = f1_iaoq_f; n_f2_iaoq_b = f1_iaoq_b;
            n_f2_iasq_f = f1_iasq_f; n_f2_iasq_b = f1_iasq_b;
            n_f2_insn = f1_word; n_f2_err = uib_err;
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
            uib_valid <= 1'b0; uib_err <= 1'b0; uib_tag <= 27'd0; burst <= 1'b0;
            for (int i = 0; i < 4; i++) uib[i] <= 64'd0;
        end else begin
            f1_valid <= n_f1_valid; f1_iaoq_f <= n_f1_iaoq_f; f1_iaoq_b <= n_f1_iaoq_b;
            f1_iasq_f <= n_f1_iasq_f; f1_iasq_b <= n_f1_iasq_b;
            f2_valid <= n_f2_valid; f2_iaoq_f <= n_f2_iaoq_f; f2_iaoq_b <= n_f2_iaoq_b;
            f2_iasq_f <= n_f2_iasq_f; f2_iasq_b <= n_f2_iasq_b; f2_insn <= n_f2_insn; f2_err <= n_f2_err;
            nf <= n_nf; nb <= n_nb; nsf <= n_nsf; nsb <= n_nsb;

            // UIB fill: non-speculative, only for a missing, unkilled F1
            if (!burst) begin
                if (f1_valid && !uib_hit && drained && !f2_valid && !redir && !redir_kill_all) begin
                    burst <= 1'b1;
                    uib_valid <= 1'b0;
                    uib_tag <= f1_iaoq_f[31:5];
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
