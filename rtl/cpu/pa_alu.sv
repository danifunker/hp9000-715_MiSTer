// PA-RISC 1.1 integer ALU: adds, subtracts, compares, logical and unit ops,
// shift-and-add, decimal correct, and the condition that decides
// nullification / conditional branches / conditional traps.
//
// Pure combinational. Semantics: PA-RISC 1.1 Architecture and Instruction
// Set Reference Manual, 3rd ed. (docs/reference/txt/Pa11_acd.txt):
//   conditions        Tables 5-1..5-6 (lines ~3652-3800)
//   overflow          Table 5-2
//   C/B bits          PSW description (line ~1146): carry out of each digit,
//                     for subtracts 0 = a borrow occurred
//   DCOR/IDCOR        GR[t] = GR[r] -/+ (6 in every digit selected by C/B)
//
// Carry/borrow bits are numbered here by digit from the right: cb[0] is the
// carry out of bits 3..0, cb[7] the carry out of bits 31..28 (the word
// carry, PA's C/B{0}). The PSW's own ordering is the CPU's business.
module pa_alu (
    input  logic [31:0] a,          // GR[r1], or the immediate (ADDI, SUBI/COMICLR: imm - GR)
    input  logic [31:0] b,          // GR[r2] (GR[r] for DCOR/IDCOR)
    input  logic [7:0]  cb_in,      // PSW carry/borrow bits
    input  logic [1:0]  a_shift,    // SHnADD: a << n before the add
    input  logic        logic_op,   // 1 = logical path, 0 = adder path
    input  logic [1:0]  lop,        // logical op: 0 AND, 1 ANDCM, 2 OR, 3 XOR
    input  logic        inv_b,      // adder: use ~b (subtract, compare, UADDCM)
    input  logic [1:0]  cin_sel,    // adder carry in: 0 -> 0, 1 -> 1, 2 -> word carry (ADDC/SUBB)
    input  logic [1:0]  dcor,       // 0 none, 1 DCOR (b - 6s), 2 IDCOR (b + 6s)
    input  logic        ds,         // DIVIDE STEP: a = (a << 1 | C/B{0}), +b or -b by PSW[V]
    input  logic        psw_v,      // PSW V (divide step)
    input  logic [1:0]  cond_class, // 0 arithmetic/compare, 1 logical, 2 unit
    input  logic [2:0]  cond_c,     // condition c field
    input  logic        cond_f,     // condition negate
    output logic [31:0] result,
    output logic [7:0]  cb_out,     // carries of this operation (adder path)
    output logic        cond_sat,   // condition satisfied
    output logic        sv,         // signed overflow (incl. SHnADD shift-out)
    output logic        uv,         // unsigned overflow (adds: carry; SHnADD: shift-out too)
    output logic        v_out       // new PSW V (divide step)
);
    // ---------------------------------------------------------------- adder
    // DCOR/IDCOR: add or subtract 6 in each digit whose C/B bit is 0 / 1.
    logic [31:0] six;
    always_comb
        for (int i = 0; i < 8; i++)
            six[4*i +: 4] = (dcor == 2'd1) ? (cb_in[i] ? 4'd0 : 4'd6)
                                           : (cb_in[i] ? 4'd6 : 4'd0);

    logic [31:0] opa, opb, opa_sh;
    always_comb begin
        if (dcor != 2'd0) begin
            opa = b;
            opb = six;
        end else begin
            opa = a;
            opb = b;
        end
        opa_sh = ds ? {opa[30:0], cb_in[7]} : (opa << a_shift);
    end

    logic        inv;
    logic        cin;
    always_comb begin
        inv = (dcor == 2'd1) ? 1'b1 : (dcor == 2'd2) ? 1'b0 : ds ? psw_v : inv_b;
        case (cin_sel)
            2'd0: cin = 1'b0;
            2'd1: cin = 1'b1;
            default: cin = cb_in[7];
        endcase
        if (ds) cin = psw_v;                   // DS: + GR[r2], or + ~GR[r2] + 1
        if (dcor == 2'd1) cin = 1'b1;          // b + ~six + 1
        else if (dcor == 2'd2) cin = 1'b0;
    end

    // one 33-bit add (the carry chain); each digit's carry out is the carry
    // into the next digit's low bit, recovered as a ^ b ^ sum
    logic [31:0] y;
    logic [32:0] full;
    logic [31:0] sum, cin_bits;
    assign y        = inv ? ~opb : opb;
    assign full     = {1'b0, opa_sh} + {1'b0, y} + {32'd0, cin};
    assign sum      = full[31:0];
    assign cin_bits = opa_sh ^ y ^ sum;            // carry into each bit
    logic [8:0] c;                                  // c[i+1] = carry out of digit i
    assign c = {full[32], cin_bits[28], cin_bits[24], cin_bits[20], cin_bits[16],
                cin_bits[12], cin_bits[8], cin_bits[4], cin};
    assign cb_out = c[8:1];

    // overflow (Table 5-2). SHnADD also overflows when the pre-shift loses
    // significant bits: unsigned if any 1 is shifted out, signed if any
    // shifted-out bit differs from the new leftmost bit.
    logic add_sv;
    assign add_sv = (opa_sh[31] == y[31]) && (sum[31] != opa_sh[31]);
    logic       sh_uv, sh_sv;
    always_comb begin
        case (ds ? 2'd1 : a_shift)
            2'd1: begin sh_uv = |opa[31];    sh_sv = (opa[31] != opa[30]); end
            2'd2: begin sh_uv = |opa[31:30]; sh_sv = (opa[31:30] != {2{opa[29]}}); end
            2'd3: begin sh_uv = |opa[31:29]; sh_sv = (opa[31:29] != {3{opa[28]}}); end
            default: begin sh_uv = 1'b0;     sh_sv = 1'b0; end
        endcase
    end
    assign sv = add_sv | sh_sv;
    assign uv = c[8] | sh_uv;
    assign v_out = c[8] ^ b[31];                // DS: PSW[V] <- carry{0} xor GR[r2]{0}

    // Condition 4/5's "unsigned overflow" (Table 5-1): for adds it is the
    // carry (or a 1 shifted out); for subtracts it is the borrow, i.e. no
    // carry -- or, for a subtracting divide step, a 1 shifted out too.
    logic sub_type, c4;
    assign sub_type = ds ? psw_v : inv_b;
    assign c4 = sub_type ? (~c[8] | sh_uv) : ~(c[8] | sh_uv);

    // -------------------------------------------------------------- logical
    logic [31:0] lres;
    always_comb
        case (lop)
            2'd0: lres = a & b;
            2'd1: lres = a & ~b;
            2'd2: lres = a | b;
            default: lres = a ^ b;
        endcase

    assign result = logic_op ? lres : sum;

    // ------------------------------------------------------------ condition
    logic zero;
    assign zero = (result == 32'd0);
    logic sat;
    always_comb begin
        sat = 1'b0;
        case (cond_class)
            2'd0: // arithmetic / compare (Table 5-1; c=4/5 use the carry for
                  // both adds and subtracts: subtract "unsigned overflow"
                  // is borrow, i.e. carry == 0)
                case (cond_c)
                    3'd0: sat = 1'b0;
                    3'd1: sat = zero;
                    3'd2: sat = result[31] ^ sv;
                    3'd3: sat = zero | (result[31] ^ sv);
                    3'd4: sat = c4;                    // NUV (adds) / << (subtracts)
                    3'd5: sat = zero | c4;
                    3'd6: sat = sv;
                    3'd7: sat = result[0];
                endcase
            2'd1: // logical (Table 5-5)
                case (cond_c)
                    3'd1: sat = zero;
                    3'd2: sat = result[31];
                    3'd3: sat = result[31] | zero;
                    3'd7: sat = result[0];
                    default: sat = 1'b0;
                endcase
            2'd2: // unit (Table 5-6): result bytes/halfwords, digit carries
                case (cond_c)
                    3'd2: sat = (result[31:24] == 0) | (result[23:16] == 0) |
                                (result[15:8] == 0)  | (result[7:0] == 0);
                    3'd3: sat = (result[31:16] == 0) | (result[15:0] == 0);
                    3'd4: sat = |cb_out;
                    3'd6: sat = cb_out[7] | cb_out[5] | cb_out[3] | cb_out[1];
                    3'd7: sat = cb_out[7] | cb_out[3];
                    default: sat = 1'b0;
                endcase
            default: sat = 1'b0;
        endcase
    end
    assign cond_sat = sat ^ cond_f;
endmodule
