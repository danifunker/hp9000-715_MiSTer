// PA-RISC 1.1 shift, extract and deposit unit: SHD/VSHD, EXTRU/EXTRS/
// VEXTRU/VEXTRS, ZDEP/DEP/ZVDEP/VDEP and the immediate deposits, with the
// shift/extract/deposit condition (Table 5-7).
//
// Pure combinational. Bit positions are PA's (bit 0 = most significant):
//   EXTR*  r,p,len  -> the len-bit field whose rightmost bit is p
//   *DEP*  r,p,len  -> deposit the low len bits so their rightmost lands at p
//   V-forms take p from SAR (CR11); VSHD shifts right by SAR, SHD by its
//   shift amount (the decoder passes the amount, not the 31-sa encoding).
//   A deposit field reaching past bit 0 is truncated (Pa11_acd "VARIABLE
//   DEPOSIT").
module pa_shift (
    input  logic [31:0] r1,        // SHD: high word; EXTR/DEP: the source GR[r]
    input  logic [31:0] r2,        // SHD: low word
    input  logic [31:0] t_old,     // DEP/DEPI: the target's old value
    input  logic [4:0]  imm5,      // DEPI/ZDEPI/VDEPI/ZVDEPI immediate (sign-extended)
    input  logic [1:0]  op,        // 0 SHD, 1 EXTRACT, 2 DEPOSIT
    input  logic        sign,      // EXTRS
    input  logic        zero_fill, // ZDEP/ZDEPI/ZVDEP/ZVDEPI
    input  logic        use_imm,   // deposit the immediate instead of r1
    input  logic [4:0]  amount,    // SHD: right shift; EXTRACT/DEPOSIT: p
    input  logic [5:0]  len,       // field length, 1..32
    input  logic [2:0]  cond_c,
    output logic [31:0] result,
    output logic        cond_sat
);
    // field mask of len bits at the right
    logic [31:0] lmask;
    assign lmask = (len >= 6'd32) ? 32'hFFFF_FFFF : ((32'd1 << len[4:0]) - 32'd1);

    logic [63:0] dbl;
    logic [31:0] ext_raw, ext, src, dep_field, dep_mask;
    logic [4:0]  rsh;
    assign rsh = 5'd31 - amount;               // LSB index of the field's right end

    always_comb begin
        // SHD: low 32 bits of (r1:r2) >> amount
        dbl = {r1, r2} >> amount;

        // EXTRACT: right-justify, then zero or sign extend from bit len-1.
        // The register is zero/sign extended to 64 bits BEFORE the shift
        // (Pa11_acd EXTRS/VEXTRS), so a field reaching past bit 0 picks up
        // copies of the sign bit: hence the arithmetic shift.
        ext_raw = sign ? 32'($signed(r1) >>> rsh) : (r1 >> rsh);
        if (sign && len < 6'd32 && ext_raw[len[4:0] - 5'd1])
            ext = ext_raw | ~lmask;
        else
            ext = ext_raw & lmask;

        // DEPOSIT: the low len bits of the source, shifted left so the
        // field's right end is at p; bits shifted past bit 0 are lost
        src       = use_imm ? {{27{imm5[4]}}, imm5} : r1;
        dep_field = (src & lmask) << rsh;
        dep_mask  = lmask << rsh;

        case (op)
            2'd0:    result = dbl[31:0];
            2'd1:    result = ext;
            default: result = zero_fill ? dep_field : ((t_old & ~dep_mask) | dep_field);
        endcase
    end

    // Table 5-7: 0 never, 1 =, 2 <, 3 OD, 4 TR, 5 <>, 6 >=, 7 EV
    always_comb
        case (cond_c)
            3'd0: cond_sat = 1'b0;
            3'd1: cond_sat = (result == 32'd0);
            3'd2: cond_sat = result[31];
            3'd3: cond_sat = result[0];
            3'd4: cond_sat = 1'b1;
            3'd5: cond_sat = (result != 32'd0);
            3'd6: cond_sat = ~result[31];
            default: cond_sat = ~result[0];
        endcase
endmodule
