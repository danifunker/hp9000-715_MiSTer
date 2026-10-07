// PA-7100LC -- sequential bring-up core (milestone A).
//
// One instruction at a time: FETCH -> EXEC -> (MEM) -> commit, over the
// uncached port of docs/design/cpu.md 6.8. It implements the architectural
// semantics (cpu.md sections 1, 3, 4) for real mode: integer, MAX-1,
// loads/stores, branches with nullification and delay slots, the system
// and PCX-L diagnose instructions, interruptions with shadow registers,
// RFI/RFIR, HPMC on bus errors and TOC. The pipelined core reuses its units
// (pa_decode, pa_alu, pa_shift, pa_max1, pa_ldst) and is checked against it.
//
// Not here yet (docs/STUBS.md S-005): virtual addressing (TLB, walker,
// PROBE/LPA), caches and cache diagnose ops, the FPU (FP instructions take
// assist emulation, trap 22), the recovery counter, group 4 traps
// (H/L/T), explicit-endian loads/stores, and CR16's fractional rate (it
// counts core clocks).
module pa_core_seq
    import pa_pkg::*;
#(
    parameter logic [31:0] RESET_PC = 32'hF000_0004
) (
    input  logic        clk,
    input  logic        rst_n,

    // uncached port (fetch and data)
    output logic        io_req,
    output logic        io_we,
    output logic [31:0] io_addr,
    output logic [7:0]  io_be,          // [7] = byte offset 0 of the doubleword
    output logic [63:0] io_wdata,       // byte offset 0 in [63:56]
    output logic        io_ifetch,
    output logic        io_rclr,        // LDCW: atomic read-and-clear
    input  logic        io_ack,
    input  logic [63:0] io_rdata,
    input  logic        io_err,

    // interrupts
    input  logic        eir_set,
    input  logic [4:0]  eir_num,
    input  logic        toc_req,

    // debug taps
    output logic        dbg_retire,
    output logic        dbg_nullified,
    output logic [31:0] dbg_iaoq_f,
    output logic [31:0] dbg_iaoq_b,
    output logic [31:0] dbg_insn,
    output logic        dbg_trap,
    output logic [5:0]  dbg_trap_vec,
    output logic [31:0] dbg_psw,
    output logic        dbg_halted,
    output logic [31:0] dbg_gr [32]       // every GR (lockstep co-simulation)
);
    // ================================================================ state
    logic [31:0] gr [32];
    logic [31:0] shr [7];             // shadows of GR 1, 8, 9, 16, 17, 24, 25
    logic [15:0] sr [8];
    logic [31:0] psw;
    logic [31:0] iaoq_f, iaoq_b;
    logic [15:0] iasq_f, iasq_b;

    // control registers
    logic [31:0] rctr, iva, eiem, eirr, iir, ior, ipsw;
    logic [31:0] pid [4];             // CR 8, 9, 12, 13
    logic [7:0]  ccr;
    logic [4:0]  sar;
    logic [31:0] cr16, cr16_cmp;
    logic [15:0] iiasq_f, iiasq_b, isr;
    logic [31:0] iiaoq_f, iiaoq_b;
    logic [31:0] tr [8];              // CR 24-31
    logic [31:0] dr [32];             // diagnose registers (DR0 rev = 0)
    logic        toc_mask, toc_pend;

    // PSW bits (PA bit k = psw[31-k])
    localparam int P_E = 26, P_N = 21, P_B = 19, P_V = 17, P_M = 16, P_Q = 3, P_I = 0;
    wire [7:0] psw_cb = psw[15:8];     // C/B{0..7}: psw[15] = C/B{0} = word carry
    wire [1:0] cur_pl = iaoq_f[1:0];

    // map pa_alu's cb[7:0] (cb[7] = word carry) onto PSW[15:8] (psw[15] = C/B{0})
    function automatic logic [7:0] cb_to_psw(input logic [7:0] cb); return cb; endfunction

    // ================================================================ FSM
    typedef enum logic [2:0] { S_FETCH, S_EXEC, S_MEM, S_TRAP } state_e;
    state_e      st;
    logic [31:0] ir;
    logic        mem_pending;

    ctrl_t c;
    pa_decode u_dec (.insn(ir), .c(c));

    // ---------------------------------------------------------------- operands
    wire [31:0] gra = gr[c.ra];
    wire [31:0] grb = gr[c.rb];
    wire [31:0] opa = c.a_imm ? c.imm : gra;

    // ---------------------------------------------------------------- ALU
    logic [31:0] alu_res;
    logic [7:0]  alu_cb;
    logic        alu_cond, alu_sv, alu_uv, alu_v;
    pa_alu u_alu (
        .a(opa), .b(grb), .cb_in(psw_cb), .a_shift(c.a_shift), .logic_op(c.logic_op),
        .lop(c.lop), .inv_b(c.inv_b), .cin_sel(c.cin_sel), .dcor(c.dcor), .ds(c.ds),
        .psw_v(psw[P_V]), .cond_class(c.cond_class), .cond_c(c.cond_c), .cond_f(c.cond_f),
        .result(alu_res), .cb_out(alu_cb), .cond_sat(alu_cond), .sv(alu_sv), .uv(alu_uv),
        .v_out(alu_v));

    // ---------------------------------------------------------------- shifter
    logic [31:0] sh_res;
    logic        sh_cond;
    pa_shift u_sh (
        .r1(gra), .r2(grb), .t_old(grb), .imm5(c.sh_imm5), .op(c.sh_op), .sign(c.sh_sign),
        .zero_fill(c.sh_zero), .use_imm(c.sh_imm),
        .amount(c.sh_sar ? sar : c.sh_amount), .len(c.sh_len), .cond_c(c.cond_c),
        .result(sh_res), .cond_sat(sh_cond));

    // ---------------------------------------------------------------- MAX-1
    logic [31:0] mx_res;
    pa_max1 u_mx (.a(gra), .b(grb), .op(c.mx_op), .sat(c.mx_sat), .sa(c.mx_sa), .result(mx_res));

    // ---------------------------------------------------------------- load/store
    logic [31:0] ls_ea, ls_new_base, ls_ld;
    logic        ls_unaligned;
    logic [3:0]  ls_be;
    logic [31:0] ls_wd, ls_word;
    pa_ldst u_ls (
        .base(grb), .index(gra), .disp(c.imm), .use_index(c.use_index), .scale(c.scale),
        .ea_is_base(c.ea_is_base), .base_trunc(c.base_trunc), .size(c.size),
        .ea(ls_ea), .new_base(ls_new_base), .unaligned(ls_unaligned),
        .stbys(c.stbys), .st_src(gra), .st_be(ls_be), .st_data(ls_wd),
        .ld_word(ls_word), .ld_data(ls_ld));
    assign ls_word = ls_ea[2] ? io_rdata[31:0] : io_rdata[63:32];

    // space of a data reference: explicit s, or SR[4 + GR[b]{0:1}]
    wire [15:0] ls_space = (c.s2 != 0) ? sr[c.s2] : sr[{1'b1, grb[31:30]}];

    // ---------------------------------------------------------------- branches
    logic        br_taken;
    logic [31:0] br_target;
    logic [15:0] br_space;
    logic        br_new_space;
    logic        movb_cond, bit_val;
    always_comb begin
        // MOVB/MOVIB: Table 5-7 on the moved value
        case (c.cond_c)
            3'd0: movb_cond = 1'b0;
            3'd1: movb_cond = (opa == 0);
            3'd2: movb_cond = opa[31];
            3'd3: movb_cond = opa[0];
            3'd4: movb_cond = 1'b1;
            3'd5: movb_cond = (opa != 0);
            3'd6: movb_cond = ~opa[31];
            default: movb_cond = ~opa[0];
        endcase
        bit_val = gra[5'd31 - (c.sh_sar ? sar : c.sh_amount)];

        br_new_space = 1'b0;
        br_space     = iasq_b;
        br_target    = iaoq_f + 32'd8 + c.disp;
        br_taken     = 1'b1;
        case (c.br)
            BR_COND: case (c.brcond)
                BC_ALU:   br_taken = alu_cond;
                BC_SHIFT: br_taken = movb_cond;
                default:  br_taken = c.cond_f ? ~bit_val : bit_val;
            endcase
            BR_BL:   ;
            BR_GATE: br_target = {br_target[31:2], 2'b00};          // C = 0: PL 0
            BR_BLR:  br_target = iaoq_f + 32'd8 + {gra[28:0], 3'b000};
            BR_BV: begin
                br_target = grb + {gra[28:0], 3'b000};
                if (br_target[1:0] < cur_pl) br_target[1:0] = cur_pl;
            end
            default: begin                                           // BE / BLE
                br_target = grb + c.disp;
                if (br_target[1:0] < cur_pl) br_target[1:0] = cur_pl;
                br_space = sr[c.sr];
                br_new_space = 1'b1;
            end
        endcase
    end
    wire br_back = c.disp[31];
    wire br_nullify = (c.br == BR_COND) ? (c.nul & (br_taken ^ br_back)) : c.nul;
    wire [31:0] link_val = iaoq_b + 32'd4;

    // ---------------------------------------------------------------- control registers
    function automatic logic cr_priv_read(input logic [4:0] n, input logic s_bit);
        case (n)
            5'd11:        cr_priv_read = 1'b0;               // SAR
            5'd26, 5'd27: cr_priv_read = 1'b0;               // TR2, TR3
            5'd16:        cr_priv_read = s_bit;              // interval timer
            default:      cr_priv_read = 1'b1;
        endcase
    endfunction

    logic [31:0] cr_rd;
    always_comb begin
        case (c.cr)
            5'd0:  cr_rd = rctr;
            5'd8:  cr_rd = {16'd0, pid[0][15:0]};
            5'd9:  cr_rd = {16'd0, pid[1][15:0]};
            5'd10: cr_rd = {24'd0, ccr};
            5'd11: cr_rd = {27'd0, sar};
            5'd12: cr_rd = {16'd0, pid[2][15:0]};
            5'd13: cr_rd = {16'd0, pid[3][15:0]};
            5'd14: cr_rd = iva;
            5'd15: cr_rd = eiem;
            5'd16: cr_rd = cr16;
            5'd17: cr_rd = {16'd0, iiasq_f};
            5'd18: cr_rd = iiaoq_f;
            5'd19: cr_rd = iir;
            5'd20: cr_rd = {16'd0, isr};
            5'd21: cr_rd = ior;
            5'd22: cr_rd = ipsw;
            5'd23: cr_rd = eirr;
            5'd24, 5'd25, 5'd26, 5'd27, 5'd28, 5'd29, 5'd30, 5'd31: cr_rd = tr[c.cr[2:0]];
            default: cr_rd = 32'd0;                          // CR1-7 reserved
        endcase
    end

    // ================================================================ execute
    // Decide the outcome of the instruction in IR (state S_EXEC), or of its
    // memory access (S_MEM): trap number, writes, next IA queue.
    logic [5:0]  ex_trap;
    logic [31:0] ex_isr_ior_addr;
    logic        ex_is_mem;
    always_comb begin
        ex_trap = TRAP_NONE;
        ex_is_mem = 1'b0;
        ex_isr_ior_addr = ls_ea;
        if (c.fu == FU_DIAG && cur_pl != 2'd0)                 // DIAG: privilege before the encoding check
            ex_trap = TRAP_PRIV_OP;
        else if (c.illegal || (c.br == BR_GATE && c.fu == FU_BRANCH && psw[P_B]))
            ex_trap = TRAP_ILLEGAL;
        else if (c.priv && cur_pl != 2'd0)
            ex_trap = TRAP_PRIV_OP;
        else if (c.assist || c.fu == FU_FP)
            ex_trap = TRAP_ASSIST_EM;
        else case (c.fu)
            FU_ALU: begin
                if (c.trap_ovf && alu_sv)                 ex_trap = TRAP_OVERFLOW;
                else if (c.trap_cond && alu_cond)         ex_trap = TRAP_COND;
            end
            FU_SYS: case (c.sysop)
                SYS_BREAK: ex_trap = TRAP_BREAK;
                SYS_MTSP:  if (c.sr[2] && c.sr[1:0] != 2'b00 && cur_pl != 0) ex_trap = TRAP_PRIV_REG;
                SYS_MTCTL: if (c.cr != 5'd11 && cur_pl != 0)             ex_trap = TRAP_PRIV_REG;
                SYS_MFCTL: if (cr_priv_read(c.cr, psw[31-6]) && cur_pl != 0) ex_trap = TRAP_PRIV_REG;
                default: ;
            endcase
            FU_LOAD, FU_STORE: begin
                if (ls_unaligned) ex_trap = TRAP_UNALIGNED;
                else ex_is_mem = 1'b1;
            end
            default: ;
        endcase
    end

    // ================================================================ sequential
    integer i;
    logic        take_int;       // external interrupt pending at the boundary
    assign take_int = psw[P_I] && ((eirr & eiem) != 0);

    // the interruption entry sequence (cpu.md 3.2)
    task automatic enter_interruption(input logic [5:0] vec, input logic [31:0] f,
                                      input logic [31:0] b, input logic [15:0] sf,
                                      input logic [15:0] sb, input logic [31:0] insn,
                                      input logic data, input logic [15:0] space,
                                      input logic [31:0] addr, input logic nul);
        logic [31:0] ip;
        ip = psw;
        ip[P_N] = nul;
        ipsw <= ip;
        if (psw[P_Q]) begin
            iiaoq_f <= f; iiaoq_b <= b;
            iiasq_f <= sf; iiasq_b <= sb;
            if (vec != TRAP_HPMC && vec != TRAP_TOC && vec != TRAP_EXT) iir <= insn;
            if (data) begin isr <= space; ior <= addr; end
        end
        shr[0] <= gr[1];  shr[1] <= gr[8];  shr[2] <= gr[9];  shr[3] <= gr[16];
        shr[4] <= gr[17]; shr[5] <= gr[24]; shr[6] <= gr[25];
        psw <= 32'd0;
        if (vec == TRAP_HPMC) psw[P_M] <= 1'b1;
        psw[P_E] <= dr[0][31-23];
        iasq_f <= 16'd0; iasq_b <= 16'd0;
        if (vec == TRAP_HPMC || vec == TRAP_TOC) begin
            iaoq_f <= 32'hF000_0000; iaoq_b <= 32'hF000_0004;
            if (vec == TRAP_TOC) begin toc_mask <= 1'b1; toc_pend <= 1'b0; end
        end else begin
            iaoq_f <= {iva[31:10], vec[4:0], 5'd0};
            iaoq_b <= {iva[31:10], vec[4:0], 5'd0} + 32'd4;
        end
        dbg_trap <= 1'b1;
        dbg_trap_vec <= vec;
    endtask

    // sequential commit of one instruction's results
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            st <= S_FETCH;
            for (i = 0; i < 32; i++) begin gr[i] <= 32'd0; dr[i] <= 32'd0; end
            for (i = 0; i < 7; i++) shr[i] <= 32'd0;
            for (i = 0; i < 8; i++) begin sr[i] <= 16'd0; tr[i] <= 32'd0; end
            for (i = 0; i < 4; i++) pid[i] <= 32'd0;
            psw <= 32'd0;
            psw[P_M] <= 1'b1;                       // reset: M only (cpu.md 1.1)
            iaoq_f <= RESET_PC; iaoq_b <= RESET_PC + 32'd4;
            iasq_f <= 16'd0; iasq_b <= 16'd0;
            rctr <= 0; iva <= 0; eiem <= 0; eirr <= 0; iir <= 0; ior <= 0; ipsw <= 0;
            ccr <= 0; sar <= 0; cr16 <= 0; cr16_cmp <= 0; iiasq_f <= 0; iiasq_b <= 0;
            isr <= 0; iiaoq_f <= 0; iiaoq_b <= 0;
            toc_mask <= 1'b1; toc_pend <= 1'b0;
            io_req <= 1'b0; io_we <= 1'b0; io_ifetch <= 1'b0; io_rclr <= 1'b0;
            io_addr <= 0; io_be <= 0; io_wdata <= 0;
            ir <= 32'd0;
            dbg_retire <= 1'b0; dbg_nullified <= 1'b0; dbg_trap <= 1'b0; dbg_trap_vec <= 0;
            dbg_iaoq_f <= 0; dbg_iaoq_b <= 0; dbg_insn <= 0; dbg_halted <= 1'b0;
        end else begin
            dbg_retire <= 1'b0;
            dbg_nullified <= 1'b0;
            dbg_trap <= 1'b0;

            // interval timer and external interrupt requests
            cr16 <= cr16 + 32'd1;
            if (cr16 + 32'd1 == cr16_cmp) eirr[31] <= 1'b1;
            if (eir_set) eirr[31 - eir_num] <= 1'b1;
            if (toc_req) toc_pend <= 1'b1;

            unique case (st)
            // ---------------------------------------------------- fetch
            S_FETCH: begin
                if (!io_req) begin
                    if (toc_pend && !toc_mask) begin
                        enter_interruption(TRAP_TOC, iaoq_f, iaoq_b, iasq_f, iasq_b, 32'd0,
                                           1'b0, 16'd0, 32'd0, psw[P_N]);
                    end else if (take_int) begin
                        enter_interruption(TRAP_EXT, iaoq_f, iaoq_b, iasq_f, iasq_b, 32'd0,
                                           1'b0, 16'd0, 32'd0, psw[P_N]);
                    end else begin
                        io_req <= 1'b1; io_we <= 1'b0; io_ifetch <= 1'b1; io_rclr <= 1'b0;
                        io_addr <= {iaoq_f[31:2], 2'b00};
                        io_be <= iaoq_f[2] ? 8'h0F : 8'hF0;
                    end
                end else if (io_ack) begin
                    io_req <= 1'b0; io_ifetch <= 1'b0;
                    if (io_err && !psw[P_M]) begin
                        enter_interruption(TRAP_HPMC, iaoq_f, iaoq_b, iasq_f, iasq_b, 32'd0,
                                           1'b0, 16'd0, 32'd0, psw[P_N]);
                    end else begin
                        ir <= iaoq_f[2] ? io_rdata[31:0] : io_rdata[63:32];
                        st <= S_EXEC;
                    end
                end
            end

            // ---------------------------------------------------- execute
            S_EXEC: begin
                st <= S_FETCH;
                dbg_iaoq_f <= iaoq_f; dbg_iaoq_b <= iaoq_b; dbg_insn <= ir;
                if (psw[P_N]) begin
                    // nullified: no effect, advance, clear N, X, B
                    psw[P_N] <= 1'b0; psw[31-11] <= 1'b0; psw[P_B] <= 1'b0;
                    iaoq_f <= iaoq_b; iaoq_b <= iaoq_b + 32'd4;
                    iasq_f <= iasq_b;
                    dbg_retire <= 1'b1; dbg_nullified <= 1'b1;
                end else if (ex_trap != TRAP_NONE) begin
                    enter_interruption(ex_trap, iaoq_f, iaoq_b, iasq_f, iasq_b, ir,
                                       ex_trap == TRAP_UNALIGNED, ls_space, ls_ea, 1'b0);
                end else if (ex_is_mem) begin
                    io_req <= 1'b1; io_ifetch <= 1'b0;
                    io_we <= (c.fu == FU_STORE);
                    io_rclr <= c.ldcw;
                    io_addr <= ls_ea;
                    if (c.fu == FU_STORE) begin
                        io_be <= ls_ea[2] ? {4'b0000, ls_be} : {ls_be, 4'b0000};
                        io_wdata <= {ls_wd, ls_wd};
                    end else
                        io_be <= ls_ea[2] ? 8'h0F : 8'hF0;
                    st <= S_MEM;
                end else begin
                    commit_nonmem();
                end
            end

            // ---------------------------------------------------- data access
            S_MEM: begin
                if (io_ack) begin
                    io_req <= 1'b0; io_we <= 1'b0; io_rclr <= 1'b0;
                    st <= S_FETCH;
                    if (io_err && !psw[P_M]) begin
                        enter_interruption(TRAP_HPMC, iaoq_f, iaoq_b, iasq_f, iasq_b, ir,
                                           1'b0, 16'd0, 32'd0, 1'b0);
                    end else begin
                        if (c.base_we && c.rb != 0) gr[c.rb] <= ls_new_base;
                        if (c.fu == FU_LOAD && c.rt != 0) gr[c.rt] <= ls_ld;   // load wins over base
                        advance(1'b0, 32'd0, 1'b0, 16'd0, 1'b0);
                    end
                end
            end
            default: st <= S_FETCH;
            endcase
            gr[0] <= 32'd0;
        end
    end

    // advance the IA queues past the instruction in IR
    task automatic advance(input logic taken, input logic [31:0] target,
                           input logic new_space, input logic [15:0] space, input logic nul);
        iaoq_f <= iaoq_b;
        iaoq_b <= taken ? target : iaoq_b + 32'd4;
        iasq_f <= iasq_b;
        iasq_b <= (taken && new_space) ? space : iasq_b;
        psw[P_N] <= nul;
        psw[P_B] <= taken;
        psw[31-11] <= 1'b0;                             // X
        dbg_retire <= 1'b1;
    endtask

    // results of a non-memory instruction
    task automatic commit_nonmem();
        case (c.fu)
            FU_ALU: begin
                if (c.rt_we && c.rt != 0) gr[c.rt] <= c.clr_result ? 32'd0 : alu_res;
                if (c.cb_we) psw[15:8] <= cb_to_psw(alu_cb);
                if (c.ds) psw[P_V] <= alu_v;
                advance(1'b0, 32'd0, 1'b0, 16'd0, c.nullify_cond & alu_cond);
            end
            FU_SHIFT: begin
                if (c.rt != 0) gr[c.rt] <= sh_res;
                advance(1'b0, 32'd0, 1'b0, 16'd0, sh_cond);
            end
            FU_MAX1: begin
                if (c.rt != 0) gr[c.rt] <= mx_res;
                advance(1'b0, 32'd0, 1'b0, 16'd0, 1'b0);
            end
            FU_BRANCH: begin
                if (c.rt_we && c.rt != 0) begin
                    if (c.link)
                        gr[c.rt] <= (c.br == BR_GATE) ? {link_val[31:2], cur_pl} : link_val;
                    else if (c.brcond == BC_SHIFT)
                        gr[c.rt] <= opa;                        // MOVB / MOVIB
                    else
                        gr[c.rt] <= alu_res;                    // ADDB / ADDIB
                end
                if (c.br == BR_BLE) sr[0] <= iasq_b;
                advance(br_taken, br_target, br_new_space, br_space, br_nullify);
            end
            FU_SYS: begin
                case (c.sysop)
                    SYS_RFI, SYS_RFIR: begin
                        psw <= ipsw;
                        iaoq_f <= iiaoq_f; iaoq_b <= iiaoq_b;
                        iasq_f <= iiasq_f; iasq_b <= iiasq_b;
                        if (c.sysop == SYS_RFIR) begin
                            gr[1] <= shr[0];  gr[8] <= shr[1];  gr[9] <= shr[2];
                            gr[16] <= shr[3]; gr[17] <= shr[4]; gr[24] <= shr[5];
                            gr[25] <= shr[6];
                        end
                        dbg_retire <= 1'b1;
                    end
                    default: begin
                        case (c.sysop)
                            SYS_SSM: begin
                                if (c.rt != 0) gr[c.rt] <= {25'd0, psw[6:0]};
                                psw[6:0] <= (psw[6:0] | c.sm_imm[6:0]) & 7'b0011111;
                            end
                            SYS_RSM: begin
                                if (c.rt != 0) gr[c.rt] <= {25'd0, psw[6:0]};
                                psw[6:0] <= psw[6:0] & ~c.sm_imm[6:0];
                            end
                            SYS_MTSM:  psw[6:0] <= gra[6:0] & 7'b0011111;
                            SYS_LDSID: if (c.rt != 0) gr[c.rt] <= {16'd0, ls_space};
                            SYS_MTSP:  sr[c.sr] <= gra[15:0];
                            SYS_MFSP:  if (c.rt != 0) gr[c.rt] <= {16'd0, sr[c.sr]};
                            SYS_MFCTL: if (c.rt != 0) gr[c.rt] <= cr_rd;
                            SYS_MTCTL: case (c.cr)
                                5'd0:  rctr <= gra;
                                5'd8:  pid[0] <= gra;
                                5'd9:  pid[1] <= gra;
                                5'd10: ccr <= gra[7:0];
                                5'd11: sar <= gra[4:0];
                                5'd12: pid[2] <= gra;
                                5'd13: pid[3] <= gra;
                                5'd14: iva <= gra;
                                5'd15: eiem <= gra;
                                5'd16: cr16_cmp <= gra;
                                5'd17: begin iiasq_f <= iiasq_b; iiasq_b <= gra[15:0]; end
                                5'd18: begin iiaoq_f <= iiaoq_b; iiaoq_b <= gra; end
                                5'd19: iir <= gra;
                                5'd20: isr <= gra[15:0];
                                5'd21: ior <= gra;
                                5'd22: ipsw <= gra;
                                5'd23: eirr <= eirr & ~gra;
                                5'd24, 5'd25, 5'd26, 5'd27, 5'd28, 5'd29, 5'd30, 5'd31:
                                       tr[c.cr[2:0]] <= gra;
                                default: ;
                            endcase
                            default: ;                          // SYNC
                        endcase
                        advance(1'b0, 32'd0, 1'b0, 16'd0, 1'b0);
                    end
                endcase
            end
            FU_DIAG: begin
                case (c.sysop)
                    DG_MTCPU:   dr[c.cr] <= gra;
                    DG_MFCPU:   if (c.rt != 0) gr[c.rt] <= dr[c.cr];
                    DG_TOC_EN:  toc_mask <= 1'b0;
                    DG_TOC_DIS: toc_mask <= 1'b1;
                    DG_SHDW_GR: begin
                        gr[1] <= shr[0];  gr[8] <= shr[1];  gr[9] <= shr[2];
                        gr[16] <= shr[3]; gr[17] <= shr[4]; gr[24] <= shr[5];
                        gr[25] <= shr[6];
                    end
                    DG_GR_SHDW: begin
                        shr[0] <= gr[1];  shr[1] <= gr[8];  shr[2] <= gr[9];
                        shr[3] <= gr[16]; shr[4] <= gr[17]; shr[5] <= gr[24];
                        shr[6] <= gr[25];
                    end
                    default: ;
                endcase
                advance(1'b0, 32'd0, 1'b0, 16'd0, 1'b0);
            end
            default: advance(1'b0, 32'd0, 1'b0, 16'd0, 1'b0);       // FU_NOP
        endcase
    endtask

    assign dbg_psw = psw;
    assign dbg_gr = gr;
endmodule
