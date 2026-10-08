// PA-7100LC floating-point unit (docs/design/cpu.md 3.5, 6.11; ERS ch. 7;
// ACD ch. 6). One operation at a time, multi-cycle, not pipelined: the core
// starts it when the instruction commits and collects the result, flags,
// compare bit or the unimplemented exception when `done` pulses.
//
// The PCX-L model (ERS s.7.3): the only exception the hardware raises is
// the unimplemented exception (a delayed trap): any NaN operand, a denormal
// operand or a tiny result with FPSR.D = 0, any IEEE exception whose trap
// is enabled, FCNVFX overflow, FRND, quad formats and reserved sub-ops. The
// datapath therefore never computes with denormals: with D = 1 they are
// signed zeroes (and tiny results flush to zero with the inexact flag).
//
// Formats: single operands arrive left-justified in bits 63:32 and single
// results return there. Internally every number is {sign, true exponent E,
// 53-bit significand with the leading 1 at bit 52}; the rounding step takes
// {significand, guard, round} plus a sticky bit. NaNs: PA-RISC marks a
// signalling NaN with fraction bit 1 = 1 (the opposite of the usual
// convention); the default quiet NaN is 0x7FF4000000000000 / 0x7FA00000.
module pa_fpu
    import pa_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    input  fpu_op_e     op,
    input  logic        sgl,            // source format single (dest too, except the converts)
    input  logic        dsgl,           // FCNV: destination format single
    input  logic [63:0] a, b,
    input  logic [1:0]  rm,             // FPSR rounding mode
    input  logic        dmode,          // FPSR D (hardware underflow mode)
    input  logic [4:0]  enables,        // FPSR trap enables {V, Z, O, U, I}
    input  logic [4:0]  cond,           // FCMP condition
    output logic        busy,
    output logic        done,           // one cycle, with the outputs below
    output logic [63:0] result,
    output logic        result_we,
    output logic [4:0]  flags,          // {V, Z, O, U, I} to set
    output logic        unimpl,         // unimplemented exception (delayed trap)
    output logic        cmp_c           // FCMP result
);
    // ---------------------------------------------------------------- classes
    typedef enum logic [2:0] { C_ZERO, C_DENORM, C_NORM, C_INF, C_QNAN, C_SNAN } cls_e;
    typedef struct packed {
        logic         s;
        logic signed [13:0] e;          // true exponent
        logic [52:0]  sig;              // 1.frac, leading 1 at bit 52 (normals)
        cls_e         c;
    } num_t;

    function automatic num_t unpack(input logic [63:0] v, input logic single);
        num_t n;
        logic [10:0] e;
        logic [51:0] f;
        logic emax;
        if (single) begin
            n.s = v[63]; e = {3'd0, v[62:55]}; f = {v[54:32], 29'd0}; emax = v[62:55] == 8'hFF;
            n.e = 14'(signed'({3'd0, v[62:55]})) - 14'sd127;
        end else begin
            n.s = v[63]; e = v[62:52]; f = v[51:0]; emax = v[62:52] == 11'h7FF;
            n.e = 14'(signed'({3'd0, v[62:52]})) - 14'sd1023;
        end
        n.sig = {1'b1, f};
        if (emax)           n.c = (f == 0) ? C_INF : f[51] ? C_SNAN : C_QNAN;
        else if (e == 0)    n.c = (f == 0) ? C_ZERO : C_DENORM;
        else                n.c = C_NORM;
        return n;
    endfunction

    // the IEEE default results, pk
    function automatic logic [63:0] pack_inf(input logic s, input logic single);
        return single ? {s, 8'hFF, 23'd0, 32'd0} : {s, 11'h7FF, 52'd0};
    endfunction
    function automatic logic [63:0] pack_max(input logic s, input logic single);
        return single ? {s, 8'hFE, {23{1'b1}}, 32'd0} : {s, 11'h7FE, {52{1'b1}}};
    endfunction
    function automatic logic [63:0] pack_zero(input logic s, input logic single);
        return single ? {s, 31'd0, 32'd0} : {s, 63'd0};
    endfunction
    localparam logic [63:0] QNAN_D = 64'h7FF4_0000_0000_0000;
    localparam logic [63:0] QNAN_S = 64'h7FA0_0000_0000_0000;

    // ---------------------------------------------------------------- state
    typedef enum logic [3:0] {
        S_IDLE, S_CLASSIFY, S_ADD_ALIGN, S_ADD_SUM, S_MUL1, S_MUL2, S_DIV, S_SQRT, S_CVT, S_CVT2, S_NORM, S_ROUND, S_DONE
    } st_e;
    st_e st;
    assign busy = st != S_IDLE;

    num_t        na, nb;                // the operands as unpacked (denormals flushed when D)
    logic        eff_sub;               // add/sub: effective subtraction
    logic        rs;                    // result sign
    logic signed [13:0] re;             // result exponent of the normalised value
    logic [57:0] rsig;                  // {leading one at some bit <= 57, ...}: normalised to bit 57 in S_NORM
    logic [57:0] add_small;             // the aligned smaller operand
    logic        rsticky;
    logic        out_single;
    logic        r_inexact_in;          // inexact already known (conversions)
    logic        is_int_result;         // FCNVFX: the integer path
    logic [63:0] int_result;
    logic        int_ovf;
    logic [63:0] cvt_ival;              // FCNVFX: the shifted magnitude (S_CVT -> S_CVT2)
    logic        cvt_g, cvt_r, cvt_s;
    // multiply
    logic [105:0] prod;
    logic [52:0]  mul_a, mul_b;
    // divide / sqrt
    logic [6:0]   iter;
    logic [55:0]  div_r;
    logic [55:0]  div_q;
    logic [57:0]  sq_rem, sq_root;
    logic [109:0] sq_rad;             // radicand m << 56: the root has 55 bits (53 + guard + round)
    // early decisions
    logic        early_done, early_unimpl, early_we;
    logic [63:0] early_result;
    logic [4:0]  early_flags;
    logic        early_cmp;

    // ---------------------------------------------------------------- helpers
    function automatic logic [5:0] lzc58(input logic [57:0] v);
        lzc58 = 6'd58;
        for (int i = 0; i < 58; i++) if (v[i]) lzc58 = 6'(57 - i);
    endfunction
    wire en_v = enables[4], en_z = enables[3], en_o = enables[2], en_i = enables[0];

    // the one right shifter with a sticky bit, shared by the add/subtract
    // alignment (S_ADD_ALIGN) and the float-to-integer conversion (S_CVT):
    // the state selects its operand and amount
    logic [57:0] sh_in, sh_out;
    logic [5:0]  sh_amt;
    logic        sh_lost;
    always_comb begin
        sh_out = sh_in >> sh_amt;
        sh_lost = (sh_amt != 0) && ((sh_in & ((58'd1 << sh_amt) - 58'd1)) != 0);
    end

    // ---------------------------------------------------------------- classify (combinational on registered operands)
    num_t ua, ub;
    always_comb begin
        ua = unpack(a, sgl); ub = unpack(b, sgl);
        if (dmode) begin                           // hardware underflow mode: denormals are signed zeroes
            if (ua.c == C_DENORM) ua.c = C_ZERO;
            if (ub.c == C_DENORM) ub.c = C_ZERO;
        end
        // a zero (or a flushed denormal) that reaches the add/subtract datapath
        // (x + 0) must weigh nothing: no implicit leading one
        if (ua.c == C_ZERO) ua.sig = 53'd0;
        if (ub.c == C_ZERO) ub.sig = 53'd0;
    end
    wire a_nan = ua.c == C_QNAN || ua.c == C_SNAN, b_nan = ub.c == C_QNAN || ub.c == C_SNAN;
    wire a_den = ua.c == C_DENORM, b_den = ub.c == C_DENORM;
    wire a_zero = ua.c == C_ZERO, b_zero = ub.c == C_ZERO, a_inf = ua.c == C_INF, b_inf = ub.c == C_INF;
    wire two_ops = op == F_ADD || op == F_SUB || op == F_MPY || op == F_DIV || op == F_CMP;
    wire b_sign_eff = (op == F_SUB) ? ~ub.s : ub.s;

    // the decisions that need no datapath (ERS s.7.3)
    logic cmp_lt, cmp_eq, cmp_gt, cmp_un;
    logic [63:0] cmp_ma, cmp_mb;         // sign-magnitude operands (denormals count by their bits)
    always_comb begin
        early_done = 1'b0; early_unimpl = 1'b0; early_we = 1'b0; early_result = 64'd0; early_flags = 5'd0; early_cmp = 1'b0;
        cmp_lt = 0; cmp_eq = 0; cmp_gt = 0; cmp_un = a_nan || b_nan;
        cmp_ma = {1'b0, a[62:0]}; cmp_mb = {1'b0, b[62:0]};
        case (op)
            F_CPY: begin early_done = 1'b1; early_we = 1'b1; early_result = a; end
            F_ABS: begin early_done = 1'b1; early_we = 1'b1; early_result = {1'b0, a[62:0]}; end
            F_RND, F_RESERVED: begin early_done = 1'b1; early_unimpl = 1'b1; end
            F_XMPYU: ;                              // the multiplier
            F_CMP: begin
                early_done = 1'b1;
                if (ua.c == C_SNAN || ub.c == C_SNAN || ((a_nan || b_nan) && cond[0])) early_unimpl = 1'b1;
                else begin
                    if (cmp_un) ;
                    else if (a_zero && b_zero) cmp_eq = 1;
                    else if (ua.s != ub.s) begin cmp_lt = ua.s; cmp_gt = ub.s; end
                    else if (cmp_ma == cmp_mb) cmp_eq = 1;
                    else begin cmp_lt = (cmp_ma < cmp_mb) ^ ua.s; cmp_gt = ~cmp_lt; end
                    early_cmp = (cmp_gt & cond[4]) | (cmp_lt & cond[3]) | (cmp_eq & cond[2]) | (cmp_un & cond[1]);
                end
            end
            F_ADD, F_SUB: begin
                if (a_nan || b_nan) begin early_done = 1'b1; early_unimpl = 1'b1; end
                else if ((a_den && !b_inf) || (b_den && !a_inf)) begin early_done = 1'b1; early_unimpl = 1'b1; end
                else if (a_inf && b_inf) begin
                    early_done = 1'b1;
                    if (ua.s != b_sign_eff) begin               // inf - inf
                        if (en_v) early_unimpl = 1'b1;
                        else begin early_we = 1'b1; early_result = sgl ? QNAN_S : QNAN_D; early_flags[4] = 1'b1; end
                    end else begin early_we = 1'b1; early_result = pack_inf(ua.s, sgl); end
                end else if (a_inf) begin early_done = 1'b1; early_we = 1'b1; early_result = pack_inf(ua.s, sgl); end
                else if (b_inf) begin early_done = 1'b1; early_we = 1'b1; early_result = pack_inf(b_sign_eff, sgl); end
                else if (a_zero && b_zero) begin
                    early_done = 1'b1; early_we = 1'b1;
                    // +0 + -0 = +0 except in round-to-minus-infinity
                    early_result = pack_zero((ua.s == b_sign_eff) ? ua.s : (rm == 2'd3), sgl);
                end
            end
            F_MPY: begin
                if (a_nan || b_nan) begin early_done = 1'b1; early_unimpl = 1'b1; end
                else if ((a_den && !(b_zero || b_inf)) || (b_den && !(a_zero || a_inf))) begin early_done = 1'b1; early_unimpl = 1'b1; end
                else if ((a_inf && b_zero) || (a_zero && b_inf)) begin
                    early_done = 1'b1;
                    if (en_v) early_unimpl = 1'b1;
                    else begin early_we = 1'b1; early_result = sgl ? QNAN_S : QNAN_D; early_flags[4] = 1'b1; end
                end else if (a_inf || b_inf) begin early_done = 1'b1; early_we = 1'b1; early_result = pack_inf(ua.s ^ ub.s, sgl); end
                else if (a_zero || b_zero) begin early_done = 1'b1; early_we = 1'b1; early_result = pack_zero(ua.s ^ ub.s, sgl); end
            end
            F_DIV: begin
                // ERS s.7.3 lists denorm/denorm, denorm/norm and norm/denorm (D = 0) as
                // unimplemented; denorm/zero is a division by zero, and the trivial
                // zero/denorm, inf/denorm, denorm/inf complete (STUBS S-013)
                if (a_nan || b_nan) begin early_done = 1'b1; early_unimpl = 1'b1; end
                else if ((a_den && (b_den || ub.c == C_NORM)) || (b_den && ua.c == C_NORM)) begin early_done = 1'b1; early_unimpl = 1'b1; end
                else if ((a_inf && b_inf) || (a_zero && b_zero)) begin
                    early_done = 1'b1;
                    if (en_v) early_unimpl = 1'b1;
                    else begin early_we = 1'b1; early_result = sgl ? QNAN_S : QNAN_D; early_flags[4] = 1'b1; end
                end else if (b_zero) begin                      // x / 0
                    early_done = 1'b1;
                    if (en_z) early_unimpl = 1'b1;
                    else begin early_we = 1'b1; early_result = pack_inf(ua.s ^ ub.s, sgl); early_flags[3] = 1'b1; end
                end else if (a_inf) begin early_done = 1'b1; early_we = 1'b1; early_result = pack_inf(ua.s ^ ub.s, sgl); end
                else if (b_inf || a_zero) begin early_done = 1'b1; early_we = 1'b1; early_result = pack_zero(ua.s ^ ub.s, sgl); end
            end
            F_SQRT: begin
                // ERS s.7.3: a negative denormal (D = 0) is an invalid operation like a
                // negative normal; only a positive denormal is unimplemented
                if (a_nan) begin early_done = 1'b1; early_unimpl = 1'b1; end
                else if (a_zero) begin early_done = 1'b1; early_we = 1'b1; early_result = pack_zero(ua.s, sgl); end
                else if (ua.s) begin                             // negative: invalid
                    early_done = 1'b1;
                    if (en_v) early_unimpl = 1'b1;
                    else begin early_we = 1'b1; early_result = sgl ? QNAN_S : QNAN_D; early_flags[4] = 1'b1; end
                end else if (a_den) begin early_done = 1'b1; early_unimpl = 1'b1; end
                else if (a_inf) begin early_done = 1'b1; early_we = 1'b1; early_result = pack_inf(1'b0, sgl); end
            end
            F_CNVFF: begin
                if (a_nan || a_den) begin early_done = 1'b1; early_unimpl = 1'b1; end
                else if (a_inf) begin early_done = 1'b1; early_we = 1'b1; early_result = pack_inf(ua.s, dsgl); end
                else if (a_zero) begin early_done = 1'b1; early_we = 1'b1; early_result = pack_zero(ua.s, dsgl); end
            end
            F_CNVFX, F_CNVFXT: begin
                if (a_nan || a_inf || a_den) begin early_done = 1'b1; early_unimpl = 1'b1; end
                else if (a_zero) begin early_done = 1'b1; early_we = 1'b1; early_result = 64'd0; end
            end
            F_CNVXF: begin
                if ((sgl ? a[63:32] : a) == 0) begin early_done = 1'b1; early_we = 1'b1; early_result = pack_zero(1'b0, dsgl); end
            end
            default: ;
        endcase
    end

    // ---------------------------------------------------------------- rounding (S_ROUND)
    // rsig[57] is the leading one; keep 53 (double) or 24 (single) bits
    logic [52:0] kept;
    logic        g, r, s_bit, inexact, round_up, lsb;
    logic [53:0] mant;
    logic signed [13:0] e_final;
    logic        ovf, tiny;
    logic [63:0] pk;
    always_comb begin
        if (out_single) begin
            kept = {29'd0, rsig[57:34]}; g = rsig[33]; r = rsig[32]; s_bit = |rsig[31:0] | rsticky; lsb = rsig[34];
        end else begin
            kept = rsig[57:5]; g = rsig[4]; r = rsig[3]; s_bit = |rsig[2:0] | rsticky; lsb = rsig[5];
        end
        inexact = g | r | s_bit | r_inexact_in;
        case (rm)
            2'd0: round_up = g & (r | s_bit | lsb);
            2'd1: round_up = 1'b0;
            2'd2: round_up = ~rs & (g | r | s_bit);
            default: round_up = rs & (g | r | s_bit);
        endcase
        mant = {1'b0, kept} + {53'd0, round_up};
        e_final = re;
        if (out_single ? mant[24] : mant[53]) begin e_final = re + 14'sd1; mant = mant >> 1; end
        ovf  = out_single ? (e_final > 14'sd127)  : (e_final > 14'sd1023);
        tiny = out_single ? (e_final < -14'sd126) : (e_final < -14'sd1022);
        if (out_single) pk = {rs, 8'(e_final + 14'sd127), mant[22:0], 32'd0};
        else            pk = {rs, 11'(e_final + 14'sd1023), mant[51:0]};
    end

    // the alignment's operand order and the shared shifter's inputs
    wire a_is_big = na.e > nb.e || (na.e == nb.e && na.sig >= nb.sig);
    always_comb begin
        logic signed [13:0] d;
        if (st == S_ADD_ALIGN) begin
            d = a_is_big ? (na.e - nb.e) : (nb.e - na.e);
            sh_in = a_is_big ? {2'b00, nb.sig, 3'd0} : {2'b00, na.sig, 3'd0};
            sh_amt = (d > 14'sd57) ? 6'd57 : 6'(d);
        end else begin                                     // S_CVT, FCNVFX(T): the units bit is bit 52 of sig,
            d = 14'sd52 - na.e;                            // shift right by 52 - e with two guard bits
            sh_in = {3'd0, na.sig, 2'b00};
            sh_amt = (d > 14'sd55) ? 6'd55 : 6'(d);
        end
    end

    // ---------------------------------------------------------------- engine
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            st <= S_IDLE; done <= 1'b0; result <= 64'd0; result_we <= 1'b0; flags <= 5'd0; unimpl <= 1'b0; cmp_c <= 1'b0;
            na <= '0; nb <= '0; eff_sub <= 0; rs <= 0; re <= 0; rsig <= 0; rsticky <= 0; out_single <= 0;
            r_inexact_in <= 0; is_int_result <= 0; int_result <= 0; int_ovf <= 0; prod <= 0; mul_a <= 0; mul_b <= 0;
            cvt_ival <= 0; cvt_g <= 0; cvt_r <= 0; cvt_s <= 0;
            iter <= 0; div_r <= 0; div_q <= 0; sq_rem <= 0; sq_root <= 0; sq_rad <= 0;
        end else begin
            done <= 1'b0;
            case (st)
                S_IDLE: if (start) begin
                    na <= ua; nb <= ub; na.s <= ua.s; nb.s <= b_sign_eff;
                    out_single <= (op == F_CNVFF || op == F_CNVXF) ? dsgl : sgl;
                    r_inexact_in <= 1'b0; is_int_result <= 1'b0; int_ovf <= 1'b0; rsticky <= 1'b0;
                    result_we <= 1'b0; flags <= 5'd0; unimpl <= 1'b0; cmp_c <= 1'b0;
                    if (early_done) begin
                        st <= S_DONE;
                        result <= early_result; result_we <= early_we; flags <= early_flags; unimpl <= early_unimpl; cmp_c <= early_cmp;
                    end else case (op)
                        F_ADD, F_SUB: st <= S_ADD_ALIGN;
                        F_MPY: begin mul_a <= ua.sig; mul_b <= ub.sig; st <= S_MUL1; end
                        F_XMPYU: begin mul_a <= {21'd0, a[63:32]}; mul_b <= {21'd0, b[63:32]}; st <= S_MUL1; end
                        F_DIV: begin
                            div_r <= {3'd0, ua.sig}; div_q <= 56'd0; iter <= 7'd0; st <= S_DIV;
                        end
                        F_SQRT: begin
                            // radicand m = sig (E even) or sig << 1 (E odd), times 2^56 so the
                            // 55-bit root = sqrt(m) * 2^28 has its leading one at bit 54
                            if (ua.e[0]) sq_rad <= {ua.sig, 1'b0, 56'd0};
                            else         sq_rad <= {1'b0, ua.sig, 56'd0};
                            sq_rem <= 58'd0; sq_root <= 58'd0; iter <= 7'd0; st <= S_SQRT;
                        end
                        default: st <= S_CVT;
                    endcase
                end

                // ---- add / subtract: align the smaller operand, add or subtract magnitudes
                S_ADD_ALIGN: begin
                    // operands as {sig, 3'b0} in 56 bits, two guard bits of headroom at the top;
                    // the smaller one goes through the shared shifter (sh_in / sh_amt below)
                    eff_sub <= na.s != nb.s;
                    rs <= a_is_big ? na.s : nb.s;
                    re <= (a_is_big ? na.e : nb.e) + 14'sd2;        // the leading one sits at bit 55
                    rsig <= a_is_big ? {2'b00, na.sig, 3'd0} : {2'b00, nb.sig, 3'd0};
                    add_small <= sh_out; rsticky <= sh_lost;
                    st <= S_ADD_SUM;
                end
                S_ADD_SUM: begin
                    logic [57:0] sum;
                    if (eff_sub) sum = rsig - add_small - {57'd0, rsticky};   // the sticky bit borrows
                    else         sum = rsig + add_small;
                    // an exact cancellation gives +0 (or -0 in round-to-minus-infinity)
                    if (sum == 58'd0 && !rsticky) begin
                        result <= pack_zero(rm == 2'd3, out_single); result_we <= 1'b1; st <= S_DONE;
                    end else begin
                        rsig <= sum;
                        st <= S_NORM;
                    end
                end

                // ---- multiply: two registered stages into the DSP blocks
                S_MUL1: begin prod <= mul_a * mul_b; st <= S_MUL2; end
                S_MUL2: begin
                    if (op == F_XMPYU) begin
                        result <= prod[63:0]; result_we <= 1'b1; st <= S_DONE;
                    end else begin
                        rs <= na.s ^ nb.s;
                        re <= na.e + nb.e + 14'sd1;
                        rsig <= prod[105:48]; rsticky <= |prod[47:0];
                        st <= S_NORM;
                    end
                end

                // ---- divide: restoring, one quotient bit per cycle, 56 steps against 2b so the
                // first digit is the units digit (a/b in (0.5, 2)): q = floor(a * 2^55 / b) < 2^56
                S_DIV: begin
                    logic [56:0] t;
                    t = {div_r, 1'b0} - {3'd0, nb.sig, 1'b0};
                    if (!t[56]) begin div_r <= t[55:0]; div_q <= {div_q[54:0], 1'b1}; end
                    else begin div_r <= {div_r[54:0], 1'b0}; div_q <= {div_q[54:0], 1'b0}; end
                    iter <= iter + 7'd1;
                    if (iter == 7'd55) begin
                        rs <= na.s ^ nb.s; re <= na.e - nb.e;             // quotient bit 55 = the units bit
                        st <= S_NORM;
                    end
                end

                // ---- square root: digit by digit, 2 radicand bits per cycle, 55 cycles for 55 root bits
                S_SQRT: begin
                    logic [57:0] rem2, trial;
                    rem2 = {sq_rem[55:0], sq_rad[109:108]};
                    trial = {sq_root[55:0], 2'b01};
                    sq_rad <= {sq_rad[107:0], 2'b00};
                    if (rem2 >= trial) begin sq_rem <= rem2 - trial; sq_root <= {sq_root[56:0], 1'b1}; end
                    else begin sq_rem <= rem2; sq_root <= {sq_root[56:0], 1'b0}; end
                    iter <= iter + 7'd1;
                    if (iter == 7'd54) st <= S_NORM;
                end

                // ---- conversions
                S_CVT: case (op)
                    F_CNVFF: begin                                 // normal in, exact or rounded
                        rs <= na.s; re <= na.e; rsig <= {na.sig, 5'd0}; st <= S_ROUND;
                    end
                    F_CNVXF: begin                                 // normalised by S_NORM's shifter
                        logic [63:0] v, mag;
                        v = sgl ? {{32{a[63]}}, a[63:32]} : a;
                        mag = v[63] ? -v : v;
                        rs <= v[63];
                        if (|mag[63:58]) begin rsig <= mag[63:6]; rsticky <= |mag[5:0]; re <= 14'sd63; end
                        else             begin rsig <= mag[57:0];  rsticky <= 1'b0;       re <= 14'sd57; end
                        st <= S_NORM;
                    end
                    default: begin                                 // F_CNVFX / F_CNVFXT: to a 32- or 64-bit integer
                        // cycle 1: the shift (the rounding and negation follow in S_CVT2)
                        logic signed [13:0] e;
                        e = na.e;
                        if (e > 14'sd63) begin int_ovf <= 1'b1; st <= S_DONE; unimpl <= 1'b1; end
                        else begin
                            if (e >= 14'sd52) begin
                                cvt_ival <= {11'd0, na.sig} << 6'(e - 14'sd52);
                                cvt_g <= 0; cvt_r <= 0; cvt_s <= 0;
                            end else begin
                                // {sig, 2'b00} >> (52 - e) through the shared shifter (sh_in / sh_amt)
                                cvt_ival <= {11'd0, sh_out[54:2]}; cvt_g <= sh_out[1]; cvt_r <= sh_out[0]; cvt_s <= sh_lost;
                            end
                            st <= S_CVT2;
                        end
                    end
                endcase
                S_CVT2: begin                                      // F_CNVFX / F_CNVFXT cycle 2: round, negate, range
                    logic [63:0] ival;
                    logic up;
                    if (op == F_CNVFXT) up = 1'b0;
                    else case (rm)
                        2'd0: up = cvt_g & (cvt_r | cvt_s | cvt_ival[0]);
                        2'd1: up = 1'b0;
                        2'd2: up = ~na.s & (cvt_g | cvt_r | cvt_s);
                        default: up = na.s & (cvt_g | cvt_r | cvt_s);
                    endcase
                    ival = cvt_ival + {63'd0, up};
                    r_inexact_in <= cvt_g | cvt_r | cvt_s;
                    is_int_result <= 1'b1;
                    if (dsgl) begin                                // 32-bit integer
                        if (na.s ? (ival > 64'h8000_0000) : (ival > 64'h7FFF_FFFF)) int_ovf <= 1'b1;
                        // ERS s.7.3 **: FCNVFX(T),dbl,sgl of -2^31 raises the unimplemented
                        // exception "even though this is not strictly necessary"
                        if (!sgl && na.s && ival == 64'h8000_0000) int_ovf <= 1'b1;
                        int_result <= {(na.s ? -ival[31:0] : ival[31:0]), 32'd0};
                    end else begin
                        if (na.s ? (ival > 64'h8000_0000_0000_0000) : ival[63]) int_ovf <= 1'b1;
                        int_result <= na.s ? -ival : ival;
                    end
                    st <= S_ROUND;
                end

                // ---- normalise the result significand so the leading one sits at bit 57
                S_NORM: begin
                    logic [5:0] lz;
                    logic [57:0] v;
                    if (op == F_DIV) begin
                        v = {div_q, 2'b00}; rsticky <= |div_r;
                    end else if (op == F_SQRT) begin
                        v = {sq_root[54:0], 3'd0}; rsticky <= |sq_rem;
                        rs <= 1'b0;
                    end else v = rsig;
                    lz = lzc58(v);
                    rsig <= v << lz;
                    if (op == F_SQRT) re <= ((na.e - 14'(signed'({13'd0, na.e[0]}))) >>> 1) - 14'(signed'({8'd0, lz}));   // all signed: E odd -> (E-1)/2
                    else re <= re - 14'(signed'({8'd0, lz}));
                    st <= S_ROUND;
                end

                // ---- round, detect the exceptions, apply the PCX-L rules
                S_ROUND: begin
                    st <= S_DONE;
                    if (is_int_result) begin
                        if (int_ovf) unimpl <= 1'b1;
                        else if (r_inexact_in && en_i) unimpl <= 1'b1;
                        else begin result <= int_result; result_we <= 1'b1; flags[0] <= r_inexact_in; end
                    end else if (ovf) begin
                        if (en_o) unimpl <= 1'b1;
                        else begin
                            // overflow with the trap disabled: the IEEE default result, O and I flags
                            logic to_inf;
                            case (rm)
                                2'd0: to_inf = 1'b1;
                                2'd1: to_inf = 1'b0;
                                2'd2: to_inf = ~rs;
                                default: to_inf = rs;
                            endcase
                            result <= to_inf ? pack_inf(rs, out_single) : pack_max(rs, out_single);
                            result_we <= 1'b1; flags[2] <= 1'b1; flags[0] <= 1'b1;
                        end
                    end else if (tiny) begin
                        if (!dmode) unimpl <= 1'b1;                // tiny result: the handler makes the denormal
                        else if (en_i) unimpl <= 1'b1;              // flushed to zero with inexact enabled
                        else begin result <= pack_zero(rs, out_single); result_we <= 1'b1; flags[0] <= 1'b1; end
                    end else if (inexact && en_i) unimpl <= 1'b1;
                    else begin result <= pk; result_we <= 1'b1; flags[0] <= inexact; end
                end
                S_DONE: begin done <= 1'b1; st <= S_IDLE; end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
